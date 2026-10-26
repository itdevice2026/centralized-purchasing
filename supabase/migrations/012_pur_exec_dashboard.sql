-- Executive (President) dashboard
-- * new role 'executive': read-only, all companies, both modules
-- * pur_exec_summary(from, to, company) returns all dashboard figures as JSON (admin / executive only)
alter table public.pur_profiles drop constraint if exists pur_profiles_role_check;
alter table public.pur_profiles add constraint pur_profiles_role_check
  check (role in ('admin','purchasing','requester','receiver','viewer','executive','accounting'));

-- ---------- Payments ----------
alter table public.pur_purchase_orders add column if not exists amount_paid numeric(14,2) not null default 0;
alter table public.pur_purchase_orders add column if not exists payment_status text not null default 'unpaid'
  check (payment_status in ('unpaid','partial','paid'));
alter table public.pur_purchase_orders add column if not exists last_payment_date date;

create table if not exists public.pur_po_payments (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.pur_purchase_orders(id) on delete cascade,
  pay_date date not null,
  amount numeric(14,2) not null check (amount > 0),
  mode text not null default 'Check' check (mode in ('Check','Bank Transfer','Cash','Online','Other')),
  reference text default '',
  remarks text default '',
  voided boolean not null default false,
  void_reason text default '',
  recorded_by uuid not null references public.pur_profiles(user_id),
  created_at timestamptz not null default now()
);
create index if not exists pur_pay_po_idx on public.pur_po_payments(po_id);
alter table public.pur_po_payments enable row level security;
create policy pur_pay_sel on public.pur_po_payments for select to authenticated using (public.pur_can_view_po(po_id));

create or replace function public.pur_has_company(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch()
      or coalesce((select role in ('executive','accounting') from public.pur_profiles where user_id = auth.uid() and active), false)
      or exists (select 1 from public.pur_user_companies uc
                   join public.pur_profiles p on p.user_id = uc.user_id and p.active
                  where uc.user_id = auth.uid() and uc.company_id = p_company)
$$;

create or replace function public.pur_po_pay_refresh(p_po uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_paid numeric; v_last date; v_total numeric;
begin
  select coalesce(sum(amount),0), max(pay_date) into v_paid, v_last from public.pur_po_payments where po_id = p_po and not voided;
  select total into v_total from public.pur_purchase_orders where id = p_po;
  perform set_config('pur.rpc','1', true);
  update public.pur_purchase_orders set amount_paid = v_paid, last_payment_date = v_last,
         payment_status = case when v_paid <= 0 then 'unpaid' when v_paid + 0.005 >= v_total then 'paid' else 'partial' end
   where id = p_po;
end $$;
revoke all on function public.pur_po_pay_refresh(uuid) from public, anon, authenticated;

create or replace function public.pur_record_payment(p_po uuid, p_date date, p_amount numeric, p_mode text, p_reference text, p_remarks text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare o public.pur_purchase_orders; v_id uuid;
begin
  if coalesce(public.pur_role(),'') not in ('admin','purchasing','accounting') then raise exception 'Only Accounting / Purchasing can record payments.'; end if;
  select * into o from public.pur_purchase_orders where id = p_po for update;
  if o.id is null then raise exception 'PO not found.'; end if;
  perform public.pur_assert_type(o.purchase_type);
  if o.status not in ('approved','sent','partial','received','closed') then raise exception 'Payments can only be recorded on approved POs (this PO is %).', o.status; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Amount must be more than zero.'; end if;
  if p_date is null then raise exception 'Payment date is required.'; end if;
  if o.amount_paid + p_amount > o.total + 0.005 then
    raise exception 'Payment of % exceeds the unpaid balance of %.', to_char(p_amount,'FM999,999,990.00'), to_char(o.total - o.amount_paid,'FM999,999,990.00'); end if;
  insert into public.pur_po_payments(po_id, pay_date, amount, mode, reference, remarks, recorded_by)
  values (p_po, p_date, round(p_amount,2), coalesce(nullif(p_mode,''),'Check'), coalesce(p_reference,''), coalesce(p_remarks,''), auth.uid())
  returning id into v_id;
  perform public.pur_po_pay_refresh(p_po);
  perform public.pur_log('PO', p_po, o.company_id, 'payment recorded', to_char(p_amount,'FM999,999,990.00') || ' on ' || p_date || coalesce(' · ' || nullif(p_reference,''), ''));
  return v_id;
end $$;

create or replace function public.pur_void_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_po uuid; v_company uuid; v_type text;
begin
  if coalesce(public.pur_role(),'') not in ('admin','accounting') then raise exception 'Only Accounting / Module Admin can void payments.'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Please give a reason.'; end if;
  select p.po_id, o.company_id, o.purchase_type into v_po, v_company, v_type
    from public.pur_po_payments p join public.pur_purchase_orders o on o.id = p.po_id where p.id = p_payment and not p.voided;
  if v_po is null then raise exception 'Payment not found or already voided.'; end if;
  perform public.pur_assert_type(v_type);
  update public.pur_po_payments set voided = true, void_reason = p_reason where id = p_payment;
  perform public.pur_po_pay_refresh(v_po);
  perform public.pur_log('PO', v_po, v_company, 'payment voided', p_reason);
end $$;
revoke execute on function public.pur_record_payment(uuid, date, numeric, text, text, text), public.pur_void_payment(uuid, text) from public, anon;
grant execute on function public.pur_record_payment(uuid, date, numeric, text, text, text), public.pur_void_payment(uuid, text) to authenticated;

create or replace function public.pur_exec_summary(p_from date, p_to date, p_company uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_live text[] := array['approved','sent','partial','received','closed'];
begin
  if coalesce(public.pur_role(),'') not in ('admin','executive') then
    raise exception 'The Executive Dashboard is for the President / Module Admin only.';
  end if;
  with po as (
    select o.*, c.code company_code, s.name supplier_name
      from public.pur_purchase_orders o
      join public.pur_companies c on c.id = o.company_id
      join public.pur_suppliers s on s.id = o.supplier_id
     where (p_company is null or o.company_id = p_company)
  ), pr as (
    select r.*, c.code company_code from public.pur_requisitions r join public.pur_companies c on c.id = r.company_id
     where (p_company is null or r.company_id = p_company)
  ), openv as (
    select l.po_id, sum(greatest(l.qty - l.qty_received, 0) * l.unit_price) open_value,
           sum(l.qty_received * l.unit_price) recv_value
      from public.pur_po_lines l group by l.po_id
  ), types as (select unnest(array['Trade','Non-Trade']) t)
  select jsonb_build_object(
    'kpi', (select jsonb_agg(jsonb_build_object(
        'type', t.t,
        'po_count', (select count(*) from po where purchase_type = t.t and status = any(v_live) and po_date between p_from and p_to),
        'po_amount', (select coalesce(sum(total),0) from po where purchase_type = t.t and status = any(v_live) and po_date between p_from and p_to),
        'pr_count', (select count(*) from pr where purchase_type = t.t and status not in ('draft','cancelled') and request_date between p_from and p_to),
        'pr_amount', (select coalesce(sum(total),0) from pr where purchase_type = t.t and status not in ('draft','cancelled') and request_date between p_from and p_to),
        'pending_pr_count', (select count(*) from pr where purchase_type = t.t and status = 'pending'),
        'pending_pr_amount', (select coalesce(sum(total),0) from pr where purchase_type = t.t and status = 'pending'),
        'pending_po_count', (select count(*) from po where purchase_type = t.t and status = 'pending'),
        'pending_po_amount', (select coalesce(sum(total),0) from po where purchase_type = t.t and status = 'pending'),
        'open_po_count', (select count(*) from po where purchase_type = t.t and status in ('approved','sent','partial')),
        'open_value', (select coalesce(sum(ov.open_value),0) from po join openv ov on ov.po_id = po.id where po.purchase_type = t.t and po.status in ('approved','sent','partial')),
        'received_value', (select coalesce(sum(ov.recv_value),0) from po join openv ov on ov.po_id = po.id where po.purchase_type = t.t and po.po_date between p_from and p_to),
        'paid_amount', (select coalesce(sum(amount_paid),0) from po where purchase_type = t.t and status = any(v_live) and po_date between p_from and p_to),
        'unpaid_amount', (select coalesce(sum(total - amount_paid),0) from po where purchase_type = t.t and status = any(v_live) and po_date between p_from and p_to),
        'paid_count', (select count(*) from po where purchase_type = t.t and status = any(v_live) and payment_status = 'paid' and po_date between p_from and p_to),
        'paid_in_period', (select coalesce(sum(pp.amount),0) from public.pur_po_payments pp join po on po.id = pp.po_id
                            where po.purchase_type = t.t and not pp.voided and pp.pay_date between p_from and p_to)
      ) order by t.t desc) from types t),
    'monthly', (select coalesce(jsonb_agg(x order by x->>'month', x->>'type'), '[]') from (
        select jsonb_build_object('month', to_char(m.m,'YYYY-MM'), 'type', t.t,
               'amount', (select coalesce(sum(total),0) from po where purchase_type = t.t and status = any(v_live)
                           and date_trunc('month', po_date) = m.m)) x
          from generate_series(date_trunc('month', p_to) - interval '11 months', date_trunc('month', p_to), interval '1 month') m(m)
          cross join types t) q),
    'by_company', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'type', t.t,
               'amount', (select coalesce(sum(total),0) from po where po.company_id = c.id and purchase_type = t.t and status = any(v_live) and po_date between p_from and p_to))
               order by c.code, t.t desc), '[]')
          from public.pur_companies c cross join types t where c.active and (p_company is null or c.id = p_company)),
    'top_suppliers', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('type', purchase_type, 'name', supplier_name, 'amount', sum(total), 'po_count', count(*)) x,
               row_number() over (partition by purchase_type order by sum(total) desc) rn
          from po where status = any(v_live) and po_date between p_from and p_to
         group by purchase_type, supplier_name) q where rn <= 10),
    'pipeline', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('doc','PR','type',purchase_type,'status',status,'count',count(*),'amount',sum(total)) x
          from pr where status not in ('cancelled') group by purchase_type, status
        union all
        select jsonb_build_object('doc','PO','type',purchase_type,'status',status,'count',count(*),'amount',sum(total))
          from po where status not in ('cancelled') group by purchase_type, status) q),
    'pending', (select coalesce(jsonb_agg(x order by (x->>'days')::int desc), '[]') from (
        select jsonb_build_object('doc', d.doc, 'id', d.id, 'no', d.no, 'type', d.ptype, 'company', d.company_code,
               'amount', d.total, 'submitted_at', d.submitted_at,
               'days', greatest(0, extract(day from now() - d.submitted_at))::int,
               'waiting_on', (select string_agg(distinct p.full_name, ', ') from public.pur_approvals a
                                join public.pur_profiles p on p.user_id = a.approver_id
                               where a.doc_id = d.id and a.status = 'pending'
                                 and a.step_no = (select min(step_no) from public.pur_approvals a2 where a2.doc_id = d.id and a2.status = 'pending'))) x
          from (select 'PR' doc, id, pr_no no, purchase_type ptype, company_code, total, submitted_at from pr where status = 'pending'
                union all
                select 'PO', id, po_no, purchase_type, company_code, total, submitted_at from po where status = 'pending') d
         order by d.submitted_at limit 50) q),
    'purchases', (select coalesce(jsonb_agg(x order by x->>'po_date' desc, x->>'po_no' desc), '[]') from (
        select jsonb_build_object('id', id, 'po_no', po_no, 'pr_no', (select pr_no from public.pur_requisitions where id = po.pr_id),
               'type', purchase_type, 'company', company_code, 'supplier', supplier_name, 'amount', total, 'status', status,
               'po_date', po_date, 'payment_status', payment_status, 'amount_paid', amount_paid, 'balance', total - amount_paid,
               'last_payment_date', last_payment_date) x
          from po where status not in ('draft','cancelled') and po_date between p_from and p_to
         order by po_date desc limit 1000) q),
    'top_pos', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('id', id, 'po_no', po_no, 'type', purchase_type, 'company', company_code, 'supplier', supplier_name,
               'amount', total, 'status', status, 'po_date', po_date) x
          from po where status = any(v_live) and po_date between p_from and p_to order by total desc limit 10) q)
  ) into v;
  return v;
end $$;
revoke execute on function public.pur_exec_summary(date, date, uuid) from public, anon;
grant execute on function public.pur_exec_summary(date, date, uuid) to authenticated;
