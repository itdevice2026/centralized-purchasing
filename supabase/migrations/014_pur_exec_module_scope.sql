-- Executive Dashboard only shows the module(s) assigned to the user (Module Users)
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
     where (p_company is null or o.company_id = p_company) and public.pur_can_type(o.purchase_type)
  ), pr as (
    select r.*, c.code company_code from public.pur_requisitions r join public.pur_companies c on c.id = r.company_id
     where (p_company is null or r.company_id = p_company) and public.pur_can_type(r.purchase_type)
  ), openv as (
    select l.po_id, sum(greatest(l.qty - l.qty_received, 0) * l.unit_price) open_value,
           sum(l.qty_received * l.unit_price) recv_value
      from public.pur_po_lines l group by l.po_id
  ), types as (select t from unnest(array['Trade','Non-Trade']) t where public.pur_can_type(t))
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
