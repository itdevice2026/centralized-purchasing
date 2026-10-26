-- =====================================================================
-- Helpers, triggers, workflow RPCs and Row Level Security
-- Status changes happen ONLY through the security-definer RPCs below
-- (they set the transaction flag pur.rpc = '1').
-- =====================================================================

-- ---------- identity helpers ----------
create or replace function public.pur_role() returns text
language sql stable security definer set search_path = '' as $$
  select role from public.pur_profiles where user_id = auth.uid() and active
$$;

create or replace function public.pur_is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'admin' from public.pur_profiles where user_id = auth.uid() and active), false)
$$;

create or replace function public.pur_is_purch() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role in ('admin','purchasing') from public.pur_profiles where user_id = auth.uid() and active), false)
$$;

create or replace function public.pur_has_company(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch()
      or exists (select 1 from public.pur_user_companies uc
                   join public.pur_profiles p on p.user_id = uc.user_id and p.active
                  where uc.user_id = auth.uid() and uc.company_id = p_company)
$$;

create or replace function public.pur_is_approver_of(p_doc uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_approvals where doc_id = p_doc and approver_id = auth.uid())
$$;

create or replace function public.pur_can_view_pr(p_pr uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_requisitions r where r.id = p_pr
                  and (public.pur_has_company(r.company_id) or r.requested_by = auth.uid()
                       or public.pur_is_approver_of(r.id)))
$$;

create or replace function public.pur_can_view_po(p_po uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_purchase_orders o where o.id = p_po
                  and (public.pur_has_company(o.company_id) or public.pur_is_approver_of(o.id)))
$$;

create or replace function public.pur_pr_editable(p_pr uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_requisitions r where r.id = p_pr
                  and r.status in ('draft','rejected')
                  and (r.requested_by = auth.uid() or public.pur_is_purch()))
$$;

create or replace function public.pur_po_editable(p_po uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch() and exists (select 1 from public.pur_purchase_orders o
                  where o.id = p_po and o.status in ('draft','rejected'))
$$;

create or replace function public.pur_cv_editable(p_cv uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch() and exists (select 1 from public.pur_canvasses c
                  where c.id = p_cv and c.status = 'draft')
$$;

-- ---------- numbering ----------
create or replace function public.pur_next_no(p_prefix text, p_company uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_code text; v_key text; v_no int; v_year text := to_char(now() at time zone 'Asia/Manila','YYYY');
begin
  if p_company is null then
    v_key := p_prefix || '-' || v_year;
  else
    select code into v_code from public.pur_companies where id = p_company;
    v_key := p_prefix || '-' || coalesce(v_code,'X') || '-' || v_year;
  end if;
  insert into public.pur_counters(key, last_no) values (v_key, 1)
  on conflict (key) do update set last_no = public.pur_counters.last_no + 1
  returning last_no into v_no;
  return v_key || '-' || lpad(v_no::text, 5, '0');
end $$;
revoke all on function public.pur_next_no(text, uuid) from public, anon, authenticated;

create or replace function public.pur_log(p_doc_type text, p_doc uuid, p_company uuid, p_action text, p_details text default '')
returns void language sql security definer set search_path = '' as $$
  insert into public.pur_activity(doc_type, doc_id, company_id, action, details, actor)
  values (p_doc_type, p_doc, p_company, p_action, coalesce(p_details,''), auth.uid())
$$;
revoke all on function public.pur_log(text, uuid, uuid, text, text) from public, anon, authenticated;

-- ---------- triggers ----------
create or replace function public.pur_tg_touch() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create or replace function public.pur_tg_pr_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.pr_no := public.pur_next_no('PR', new.company_id);
    new.status := 'draft';
    new.total := 0;
    if not public.pur_is_purch() then new.requested_by := auth.uid(); end if;
  else
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then
      if new.status is distinct from old.status or new.pr_no is distinct from old.pr_no
         or new.company_id is distinct from old.company_id or new.requested_by is distinct from old.requested_by then
        raise exception 'Status / number / company can only be changed through the workflow.';
      end if;
      if old.status not in ('draft','rejected') then
        raise exception 'PR % is % and can no longer be edited.', old.pr_no, old.status;
      end if;
    end if;
    new.updated_at := now();
  end if;
  return new;
end $$;

create or replace function public.pur_tg_po_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_sum numeric;
begin
  if tg_op = 'INSERT' then
    new.po_no := public.pur_next_no('PO', new.company_id);
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then new.status := 'draft'; end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then
      if new.status is distinct from old.status or new.po_no is distinct from old.po_no
         or new.company_id is distinct from old.company_id then
        raise exception 'Status / number / company can only be changed through the workflow.';
      end if;
      if old.status not in ('draft','rejected') then
        raise exception 'PO % is % and can no longer be edited.', old.po_no, old.status;
      end if;
    end if;
    new.updated_at := now();
  end if;
  select coalesce(sum(amount),0) into v_sum from public.pur_po_lines where po_id = new.id;
  if new.vat_type = 'VAT-EXCLUSIVE' then
    new.subtotal := v_sum; new.vat_amount := round(v_sum * 0.12, 2); new.total := new.subtotal + new.vat_amount;
  elsif new.vat_type = 'VAT-INCLUSIVE' then
    new.total := v_sum; new.vat_amount := round(v_sum * 12 / 112, 2); new.subtotal := new.total - new.vat_amount;
  else
    new.subtotal := v_sum; new.vat_amount := 0; new.total := v_sum;
  end if;
  return new;
end $$;

create or replace function public.pur_tg_cv_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    select company_id into new.company_id from public.pur_requisitions where id = new.pr_id;
    new.cv_no := public.pur_next_no('CV', new.company_id);
    new.status := 'draft';
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif coalesce(current_setting('pur.rpc', true),'') <> '1' then
    if new.status is distinct from old.status or new.pr_id is distinct from old.pr_id then
      raise exception 'Canvass status can only be changed through the workflow.';
    end if;
    if old.status <> 'draft' then raise exception 'Canvass % is % and can no longer be edited.', old.cv_no, old.status; end if;
  end if;
  return new;
end $$;

-- recompute PR total
create or replace function public.pur_tg_pr_lines_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_pr uuid := coalesce(new.pr_id, old.pr_id); v_flag text := coalesce(current_setting('pur.rpc', true),'');
begin
  perform set_config('pur.rpc','1', true);
  update public.pur_requisitions
     set total = (select coalesce(sum(amount),0) from public.pur_pr_lines where pr_id = v_pr)
   where id = v_pr;
  perform set_config('pur.rpc', v_flag, true);
  return null;
end $$;

-- recompute PO totals (touch row -> before trigger recalculates)
create or replace function public.pur_tg_po_lines_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_po uuid := coalesce(new.po_id, old.po_id); v_flag text := coalesce(current_setting('pur.rpc', true),'');
begin
  perform set_config('pur.rpc','1', true);
  update public.pur_purchase_orders set updated_at = now() where id = v_po;
  perform set_config('pur.rpc', v_flag, true);
  return null;
end $$;

drop trigger if exists pur_pr_before on public.pur_requisitions;
create trigger pur_pr_before before insert or update on public.pur_requisitions
  for each row execute function public.pur_tg_pr_before();
drop trigger if exists pur_po_before on public.pur_purchase_orders;
create trigger pur_po_before before insert or update on public.pur_purchase_orders
  for each row execute function public.pur_tg_po_before();
drop trigger if exists pur_cv_before on public.pur_canvasses;
create trigger pur_cv_before before insert or update on public.pur_canvasses
  for each row execute function public.pur_tg_cv_before();
drop trigger if exists pur_pr_lines_after on public.pur_pr_lines;
create trigger pur_pr_lines_after after insert or update or delete on public.pur_pr_lines
  for each row execute function public.pur_tg_pr_lines_after();
drop trigger if exists pur_po_lines_after on public.pur_po_lines;
create trigger pur_po_lines_after after insert or update or delete on public.pur_po_lines
  for each row execute function public.pur_tg_po_lines_after();
drop trigger if exists pur_items_touch on public.pur_items;
create trigger pur_items_touch before update on public.pur_items for each row execute function public.pur_tg_touch();
drop trigger if exists pur_suppliers_touch on public.pur_suppliers;
create trigger pur_suppliers_touch before update on public.pur_suppliers for each row execute function public.pur_tg_touch();

-- auto codes for masters
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text := case when tg_table_name = 'pur_items' then 'ITM' else 'SUP' end; v_no int;
begin
  if new.code is null or btrim(new.code) = '' then
    insert into public.pur_counters(key, last_no) values (v_prefix, 1)
    on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
    new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;
drop trigger if exists pur_items_code on public.pur_items;
create trigger pur_items_code before insert on public.pur_items for each row execute function public.pur_tg_master_code();
drop trigger if exists pur_suppliers_code on public.pur_suppliers;
create trigger pur_suppliers_code before insert on public.pur_suppliers for each row execute function public.pur_tg_master_code();

-- =====================================================================
-- WORKFLOW RPCs
-- =====================================================================

-- Submit PR or PO for approval (builds approver steps from matrix by amount)
create or replace function public.pur_submit(p_doc_type text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_company uuid; v_total numeric; v_status text; v_owner uuid; v_no text; v_round int; v_steps int;
begin
  if p_doc_type = 'PR' then
    select company_id, total, status, requested_by, pr_no into v_company, v_total, v_status, v_owner, v_no
      from public.pur_requisitions where id = p_id for update;
    if v_company is null then raise exception 'PR not found.'; end if;
    if v_owner <> auth.uid() and not public.pur_is_purch() then raise exception 'Only the requester or Purchasing can submit this PR.'; end if;
    if not exists (select 1 from public.pur_pr_lines where pr_id = p_id) then raise exception 'Add at least one item line before submitting.'; end if;
  elsif p_doc_type = 'PO' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can submit a PO.'; end if;
    select company_id, total, status, po_no into v_company, v_total, v_status, v_no
      from public.pur_purchase_orders where id = p_id for update;
    if v_company is null then raise exception 'PO not found.'; end if;
    if not exists (select 1 from public.pur_po_lines where po_id = p_id) then raise exception 'Add at least one item line before submitting.'; end if;
  else
    raise exception 'Unknown document type.';
  end if;
  if v_status not in ('draft','rejected') then raise exception '% is already %.', v_no, v_status; end if;

  select coalesce(max(round),0) + 1 into v_round from public.pur_approvals where doc_id = p_id;
  insert into public.pur_approvals(doc_type, doc_id, company_id, round, step_no, step_name, approver_id)
  select p_doc_type, p_id, v_company, v_round, r.step_no, r.step_name, r.approver_id
    from public.pur_approval_rules r
    join public.pur_profiles p on p.user_id = r.approver_id and p.active
   where r.company_id = v_company and r.doc_type = p_doc_type and r.min_amount <= v_total;
  get diagnostics v_steps = row_count;
  if v_steps = 0 then
    raise exception 'No approvers are set up for % of this company. Ask the Module Admin to configure the Approval Matrix.', p_doc_type;
  end if;

  perform set_config('pur.rpc','1', true);
  if p_doc_type = 'PR' then
    update public.pur_requisitions set status = 'pending', submitted_at = now() where id = p_id;
  else
    update public.pur_purchase_orders set status = 'pending', submitted_at = now() where id = p_id;
  end if;
  perform public.pur_log(p_doc_type, p_id, v_company, 'submitted', 'Amount ' || to_char(v_total,'FM999,999,999,990.00'));
  return 'pending';
end $$;

-- Approve / reject the current step
create or replace function public.pur_act(p_approval_id uuid, p_decision text, p_remarks text default '') returns text
language plpgsql security definer set search_path = '' as $$
declare a public.pur_approvals; v_cur int; v_left int; v_new text;
begin
  select * into a from public.pur_approvals where id = p_approval_id for update;
  if a.id is null then raise exception 'Approval not found.'; end if;
  if a.approver_id <> auth.uid() then raise exception 'This approval is assigned to someone else.'; end if;
  if a.status <> 'pending' then raise exception 'This step was already %.', a.status; end if;
  select min(step_no) into v_cur from public.pur_approvals where doc_id = a.doc_id and round = a.round and status = 'pending';
  if a.step_no <> v_cur then raise exception 'Earlier approval steps are still pending.'; end if;

  perform set_config('pur.rpc','1', true);
  if p_decision = 'approve' then
    update public.pur_approvals set status = 'approved', remarks = coalesce(p_remarks,''), acted_at = now() where id = a.id;
    update public.pur_approvals set status = 'skipped', acted_at = now()
     where doc_id = a.doc_id and round = a.round and step_no = a.step_no and status = 'pending';
    select count(*) into v_left from public.pur_approvals where doc_id = a.doc_id and round = a.round and status = 'pending';
    if v_left = 0 then
      v_new := 'approved';
      if a.doc_type = 'PR' then
        update public.pur_requisitions set status = 'approved', approved_at = now() where id = a.doc_id;
      else
        update public.pur_purchase_orders set status = 'approved', approved_at = now() where id = a.doc_id;
        update public.pur_items i set last_price = l.unit_price
          from public.pur_po_lines l where l.po_id = a.doc_id and l.item_id = i.id;
      end if;
    else
      v_new := 'pending';
    end if;
    perform public.pur_log(a.doc_type, a.doc_id, a.company_id, 'approved step ' || a.step_no, p_remarks);
  elsif p_decision = 'reject' then
    if coalesce(btrim(p_remarks),'') = '' then raise exception 'Please give a reason for rejecting.'; end if;
    update public.pur_approvals set status = 'rejected', remarks = p_remarks, acted_at = now() where id = a.id;
    update public.pur_approvals set status = 'skipped', acted_at = now()
     where doc_id = a.doc_id and round = a.round and status = 'pending';
    v_new := 'rejected';
    if a.doc_type = 'PR' then
      update public.pur_requisitions set status = 'rejected' where id = a.doc_id;
    else
      update public.pur_purchase_orders set status = 'rejected' where id = a.doc_id;
    end if;
    perform public.pur_log(a.doc_type, a.doc_id, a.company_id, 'rejected at step ' || a.step_no, p_remarks);
  else
    raise exception 'Decision must be approve or reject.';
  end if;
  return v_new;
end $$;

-- Cancel a PR / PO / Canvass
create or replace function public.pur_cancel(p_doc_type text, p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_owner uuid; v_company uuid;
begin
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Please give a reason for cancelling.'; end if;
  perform set_config('pur.rpc','1', true);
  if p_doc_type = 'PR' then
    select status, requested_by, company_id into v_status, v_owner, v_company from public.pur_requisitions where id = p_id for update;
    if not (v_owner = auth.uid() or public.pur_is_purch()) then raise exception 'Not allowed.'; end if;
    if v_status not in ('draft','pending','rejected','approved','canvassing') then raise exception 'PR is % and cannot be cancelled.', v_status; end if;
    if exists (select 1 from public.pur_purchase_orders where pr_id = p_id and status <> 'cancelled') then
      raise exception 'Cancel the POs of this PR first.'; end if;
    update public.pur_requisitions set status = 'cancelled' where id = p_id;
    update public.pur_canvasses set status = 'cancelled' where pr_id = p_id and status = 'draft';
  elsif p_doc_type = 'PO' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can cancel a PO.'; end if;
    select status, company_id into v_status, v_company from public.pur_purchase_orders where id = p_id for update;
    if v_status in ('partial','received','closed','cancelled') then raise exception 'PO is % and cannot be cancelled.', v_status; end if;
    update public.pur_purchase_orders set status = 'cancelled' where id = p_id;
    -- re-open PR for re-ordering if no live PO remains
    update public.pur_requisitions r set status = 'approved'
     where r.id = (select pr_id from public.pur_purchase_orders where id = p_id) and r.status = 'ordered'
       and not exists (select 1 from public.pur_purchase_orders o where o.pr_id = r.id and o.status <> 'cancelled');
  elsif p_doc_type = 'CV' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can cancel a canvass.'; end if;
    select status, company_id into v_status, v_company from public.pur_canvasses where id = p_id for update;
    if v_status <> 'draft' then raise exception 'Only a draft canvass can be cancelled.'; end if;
    update public.pur_canvasses set status = 'cancelled' where id = p_id;
    update public.pur_requisitions r set status = 'approved'
     where r.id = (select pr_id from public.pur_canvasses where id = p_id) and r.status = 'canvassing';
  else raise exception 'Unknown document type.';
  end if;
  update public.pur_approvals set status = 'skipped', acted_at = now() where doc_id = p_id and status = 'pending';
  perform public.pur_log(p_doc_type, p_id, v_company, 'cancelled', p_reason);
end $$;

-- Start a canvass for an approved PR
create or replace function public.pur_start_canvass(p_pr uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_company uuid; v_id uuid;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can canvass.'; end if;
  select status, company_id into v_status, v_company from public.pur_requisitions where id = p_pr for update;
  if v_status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', v_status; end if;
  select id into v_id from public.pur_canvasses where pr_id = p_pr and status = 'draft' limit 1;
  if v_id is not null then return v_id; end if;
  insert into public.pur_canvasses(pr_id, company_id, created_by) values (p_pr, v_company, auth.uid()) returning id into v_id;
  perform set_config('pur.rpc','1', true);
  update public.pur_requisitions set status = 'canvassing' where id = p_pr;
  perform public.pur_log('CV', v_id, v_company, 'created', '');
  return v_id;
end $$;

-- Award canvass: one awarded supplier per PR line, then generate draft POs per supplier
create or replace function public.pur_award_canvass(p_cv uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare c public.pur_canvasses; v_missing int; v_multi int; s record; v_po uuid; v_count int := 0; v_pr record;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can award a canvass.'; end if;
  select * into c from public.pur_canvasses where id = p_cv for update;
  if c.status <> 'draft' then raise exception 'Canvass is already %.', c.status; end if;
  select count(*) into v_missing from public.pur_pr_lines l
   where l.pr_id = c.pr_id and not exists (select 1 from public.pur_canvass_prices p where p.canvass_id = p_cv and p.pr_line_id = l.id and p.awarded);
  if v_missing > 0 then raise exception '% PR line(s) have no awarded supplier.', v_missing; end if;
  select count(*) into v_multi from (select pr_line_id from public.pur_canvass_prices where canvass_id = p_cv and awarded group by pr_line_id having count(*) > 1) x;
  if v_multi > 0 then raise exception 'Each PR line can be awarded to only one supplier.'; end if;

  select * into v_pr from public.pur_requisitions where id = c.pr_id;
  perform set_config('pur.rpc','1', true);
  update public.pur_canvasses set status = 'awarded', awarded_at = now() where id = p_cv;

  for s in select cs.id cs_id, cs.supplier_id, cs.payment_terms, sp.vat_type
             from public.pur_canvass_suppliers cs join public.pur_suppliers sp on sp.id = cs.supplier_id
            where cs.canvass_id = p_cv
              and exists (select 1 from public.pur_canvass_prices p where p.cs_id = cs.id and p.awarded) loop
    insert into public.pur_purchase_orders(company_id, supplier_id, pr_id, canvass_id, delivery_date, payment_terms, vat_type, created_by, status, delivery_address)
    values (c.company_id, s.supplier_id, c.pr_id, p_cv, v_pr.date_needed, coalesce(s.payment_terms,''),
            case when s.vat_type = 'NON-VAT' then 'NON-VAT' else 'VAT-EXCLUSIVE' end, auth.uid(), 'draft',
            coalesce((select address from public.pur_companies where id = c.company_id),''))
    returning id into v_po;
    insert into public.pur_po_lines(po_id, line_no, pr_line_id, item_id, description, uom, qty, unit_price)
    select v_po, row_number() over (order by l.line_no), l.id, l.item_id, l.description, l.uom, l.qty, p.unit_price
      from public.pur_canvass_prices p join public.pur_pr_lines l on l.id = p.pr_line_id
     where p.cs_id = s.cs_id and p.awarded;
    perform public.pur_log('PO', v_po, c.company_id, 'created from canvass', c.cv_no);
    v_count := v_count + 1;
  end loop;
  update public.pur_requisitions set status = 'ordered' where id = c.pr_id;
  perform public.pur_log('CV', p_cv, c.company_id, 'awarded', v_count || ' PO(s) generated');
  return v_count;
end $$;

-- Direct PO from an approved PR (no canvass) to one supplier
create or replace function public.pur_po_from_pr(p_pr uuid, p_supplier uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.pur_requisitions; v_po uuid; v_vat text; v_terms text;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can create a PO.'; end if;
  select * into r from public.pur_requisitions where id = p_pr for update;
  if r.status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', r.status; end if;
  select case when vat_type = 'NON-VAT' then 'NON-VAT' else 'VAT-EXCLUSIVE' end, payment_terms into v_vat, v_terms
    from public.pur_suppliers where id = p_supplier and status = 'active';
  if v_vat is null then raise exception 'Supplier is not active / approved.'; end if;
  perform set_config('pur.rpc','1', true);
  insert into public.pur_purchase_orders(company_id, supplier_id, pr_id, delivery_date, payment_terms, vat_type, created_by, status, delivery_address)
  values (r.company_id, p_supplier, p_pr, r.date_needed, coalesce(v_terms,''), v_vat, auth.uid(), 'draft',
          coalesce((select address from public.pur_companies where id = r.company_id),''))
  returning id into v_po;
  insert into public.pur_po_lines(po_id, line_no, pr_line_id, item_id, description, uom, qty, unit_price)
  select v_po, line_no, id, item_id, description, uom, qty, est_unit_cost from public.pur_pr_lines where pr_id = p_pr;
  update public.pur_canvasses set status = 'cancelled' where pr_id = p_pr and status = 'draft';
  update public.pur_requisitions set status = 'ordered' where id = p_pr;
  perform public.pur_log('PO', v_po, r.company_id, 'created from PR', r.pr_no);
  return v_po;
end $$;

create or replace function public.pur_mark_sent(p_po uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_company uuid;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can do this.'; end if;
  select status, company_id into v_status, v_company from public.pur_purchase_orders where id = p_po for update;
  if v_status <> 'approved' then raise exception 'Only an approved PO can be marked as sent.'; end if;
  perform set_config('pur.rpc','1', true);
  update public.pur_purchase_orders set status = 'sent' where id = p_po;
  perform public.pur_log('PO', p_po, v_company, 'sent to supplier', '');
end $$;

-- Receive against a PO. p_lines = [{po_line_id, qty_received, qty_rejected, remarks}]
create or replace function public.pur_receive(p_po uuid, p_received_date date, p_dr_no text, p_invoice_no text, p_remarks text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare o public.pur_purchase_orders; v_rr uuid; l jsonb; pl public.pur_po_lines; v_q numeric; v_rej numeric; v_open int; v_any boolean := false;
begin
  select * into o from public.pur_purchase_orders where id = p_po for update;
  if o.id is null then raise exception 'PO not found.'; end if;
  if coalesce(public.pur_role(),'') not in ('admin','purchasing','receiver') or not public.pur_has_company(o.company_id) then
    raise exception 'You are not allowed to receive for this company.'; end if;
  if o.status not in ('approved','sent','partial') then raise exception 'PO is % and cannot be received.', o.status; end if;

  insert into public.pur_receivings(rr_no, po_id, company_id, received_by, received_date, dr_no, invoice_no, remarks)
  values (public.pur_next_no('RR', o.company_id), p_po, o.company_id, auth.uid(), coalesce(p_received_date, current_date),
          coalesce(p_dr_no,''), coalesce(p_invoice_no,''), coalesce(p_remarks,''))
  returning id into v_rr;

  for l in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_q := coalesce((l->>'qty_received')::numeric, 0);
    v_rej := coalesce((l->>'qty_rejected')::numeric, 0);
    if v_q = 0 and v_rej = 0 then continue; end if;
    if v_q < 0 or v_rej < 0 then raise exception 'Quantities cannot be negative.'; end if;
    select * into pl from public.pur_po_lines where id = (l->>'po_line_id')::uuid and po_id = p_po for update;
    if pl.id is null then raise exception 'Line does not belong to this PO.'; end if;
    if pl.qty_received + v_q > pl.qty then
      raise exception 'Line "%": receiving % exceeds the remaining % %.', pl.description, v_q, pl.qty - pl.qty_received, pl.uom; end if;
    insert into public.pur_rr_lines(rr_id, po_line_id, qty_received, qty_rejected, remarks)
    values (v_rr, pl.id, v_q, v_rej, coalesce(l->>'remarks',''));
    perform set_config('pur.rpc','1', true);
    update public.pur_po_lines set qty_received = qty_received + v_q where id = pl.id;
    v_any := true;
  end loop;
  if not v_any then raise exception 'Enter at least one received quantity.'; end if;

  perform set_config('pur.rpc','1', true);
  select count(*) into v_open from public.pur_po_lines where po_id = p_po and qty_received < qty;
  update public.pur_purchase_orders set status = case when v_open = 0 then 'received' else 'partial' end where id = p_po;
  -- close the PR when every live PO is fully received
  update public.pur_requisitions r set status = 'closed'
   where r.id = o.pr_id and r.status = 'ordered'
     and not exists (select 1 from public.pur_purchase_orders x where x.pr_id = r.id and x.status not in ('received','closed','cancelled'));
  perform public.pur_log('PO', p_po, o.company_id, 'received', (select rr_no from public.pur_receivings where id = v_rr));
  return v_rr;
end $$;

-- ---------- Master data change requests (Module Admin approval) ----------
create or replace function public.pur_master_request(p_kind text, p_action text, p_target uuid, p_payload jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if coalesce(public.pur_role(),'viewer') = 'viewer' then raise exception 'You are not allowed to request master data changes.'; end if;
  if p_kind not in ('item','supplier') then raise exception 'Unknown master type.'; end if;
  if p_action <> 'create' and p_target is null then raise exception 'Select the record to change.'; end if;
  if p_action = 'create' then
    if p_kind = 'item' and coalesce(btrim(p_payload->>'description'),'') = '' then raise exception 'Item description is required.'; end if;
    if p_kind = 'supplier' and coalesce(btrim(p_payload->>'name'),'') = '' then raise exception 'Supplier name is required.'; end if;
  end if;
  if p_target is not null and exists (select 1 from public.pur_master_requests where target_id = p_target and status = 'pending') then
    raise exception 'There is already a pending request for this record.'; end if;
  insert into public.pur_master_requests(req_no, kind, action, target_id, payload, reason, requested_by)
  values (public.pur_next_no(case when p_kind = 'item' then 'MRI' else 'MRS' end, null), p_kind, p_action, p_target,
          coalesce(p_payload,'{}'::jsonb), coalesce(p_reason,''), auth.uid())
  returning id into v_id;
  perform public.pur_log('MR', v_id, null, 'requested ' || p_action || ' ' || p_kind, p_reason);
  return v_id;
end $$;

create or replace function public.pur_master_review(p_id uuid, p_decision text, p_remarks text default '')
returns uuid language plpgsql security definer set search_path = '' as $$
declare m public.pur_master_requests; v_res uuid; j jsonb;
begin
  if not public.pur_is_admin() then raise exception 'Only the Module Admin can approve master data changes.'; end if;
  select * into m from public.pur_master_requests where id = p_id for update;
  if m.status <> 'pending' then raise exception 'Request is already %.', m.status; end if;
  if p_decision = 'reject' then
    if coalesce(btrim(p_remarks),'') = '' then raise exception 'Please give a reason for rejecting.'; end if;
    update public.pur_master_requests set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_remarks = p_remarks where id = p_id;
    perform public.pur_log('MR', p_id, null, 'rejected', p_remarks);
    return null;
  elsif p_decision <> 'approve' then raise exception 'Decision must be approve or reject.';
  end if;
  j := m.payload;
  if m.kind = 'item' then
    if m.action = 'create' then
      insert into public.pur_items(code, description, uom, category, specs, last_price)
      values (nullif(btrim(j->>'code'),''), btrim(j->>'description'), upper(coalesce(nullif(btrim(j->>'uom'),''),'PC')),
              coalesce(j->>'category',''), coalesce(j->>'specs',''), coalesce(nullif(j->>'last_price','')::numeric,0))
      returning id into v_res;
    elsif m.action = 'update' then
      update public.pur_items set
        description = coalesce(nullif(btrim(j->>'description'),''), description),
        uom = upper(coalesce(nullif(btrim(j->>'uom'),''), uom)),
        category = coalesce(j->>'category', category),
        specs = coalesce(j->>'specs', specs),
        last_price = coalesce(nullif(j->>'last_price','')::numeric, last_price)
      where id = m.target_id returning id into v_res;
    else
      update public.pur_items set status = case when m.action = 'activate' then 'active' else 'inactive' end
       where id = m.target_id returning id into v_res;
    end if;
  else
    if m.action = 'create' then
      insert into public.pur_suppliers(code, name, tin, address, contact_person, phone, email, payment_terms, vat_type, category)
      values (nullif(btrim(j->>'code'),''), btrim(j->>'name'), coalesce(j->>'tin',''), coalesce(j->>'address',''),
              coalesce(j->>'contact_person',''), coalesce(j->>'phone',''), coalesce(j->>'email',''),
              coalesce(j->>'payment_terms',''), coalesce(nullif(j->>'vat_type',''),'VAT'), coalesce(j->>'category',''))
      returning id into v_res;
    elsif m.action = 'update' then
      update public.pur_suppliers set
        name = coalesce(nullif(btrim(j->>'name'),''), name),
        tin = coalesce(j->>'tin', tin), address = coalesce(j->>'address', address),
        contact_person = coalesce(j->>'contact_person', contact_person), phone = coalesce(j->>'phone', phone),
        email = coalesce(j->>'email', email), payment_terms = coalesce(j->>'payment_terms', payment_terms),
        vat_type = coalesce(nullif(j->>'vat_type',''), vat_type), category = coalesce(j->>'category', category)
      where id = m.target_id returning id into v_res;
    else
      update public.pur_suppliers set status = case when m.action = 'activate' then 'active' else 'inactive' end
       where id = m.target_id returning id into v_res;
    end if;
  end if;
  if v_res is null then raise exception 'Target record not found.'; end if;
  update public.pur_master_requests set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
         review_remarks = coalesce(p_remarks,''), result_id = v_res where id = p_id;
  perform public.pur_log('MR', p_id, null, 'approved', p_remarks);
  return v_res;
end $$;

create or replace function public.pur_master_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.pur_master_requests set status = 'cancelled', reviewed_at = now()
   where id = p_id and status = 'pending' and (requested_by = auth.uid() or public.pur_is_admin());
  if not found then raise exception 'Request cannot be cancelled.'; end if;
end $$;

-- Used only by the pur-admin edge function (service role)
create or replace function public.pur_find_user(p_email text) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from auth.users where lower(email) = lower(btrim(p_email)) limit 1
$$;
revoke all on function public.pur_find_user(text) from public, anon, authenticated;
grant execute on function public.pur_find_user(text) to service_role;

-- lock internal trigger fns from direct calls
revoke all on function public.pur_tg_pr_before() from public, anon, authenticated;
revoke all on function public.pur_tg_po_before() from public, anon, authenticated;
revoke all on function public.pur_tg_cv_before() from public, anon, authenticated;
revoke all on function public.pur_tg_pr_lines_after() from public, anon, authenticated;
revoke all on function public.pur_tg_po_lines_after() from public, anon, authenticated;
revoke all on function public.pur_tg_master_code() from public, anon, authenticated;
revoke execute on function public.pur_submit(text, uuid) from public, anon;
revoke execute on function public.pur_act(uuid, text, text) from public, anon;
revoke execute on function public.pur_cancel(text, uuid, text) from public, anon;
revoke execute on function public.pur_start_canvass(uuid) from public, anon;
revoke execute on function public.pur_award_canvass(uuid) from public, anon;
revoke execute on function public.pur_po_from_pr(uuid, uuid) from public, anon;
revoke execute on function public.pur_mark_sent(uuid) from public, anon;
revoke execute on function public.pur_receive(uuid, date, text, text, text, jsonb) from public, anon;
revoke execute on function public.pur_master_request(text, text, uuid, jsonb, text) from public, anon;
revoke execute on function public.pur_master_review(uuid, text, text) from public, anon;
revoke execute on function public.pur_master_cancel(uuid) from public, anon;
grant execute on function public.pur_submit(text, uuid), public.pur_act(uuid, text, text), public.pur_cancel(text, uuid, text),
  public.pur_start_canvass(uuid), public.pur_award_canvass(uuid), public.pur_po_from_pr(uuid, uuid), public.pur_mark_sent(uuid),
  public.pur_receive(uuid, date, text, text, text, jsonb), public.pur_master_request(text, text, uuid, jsonb, text),
  public.pur_master_review(uuid, text, text), public.pur_master_cancel(uuid) to authenticated;

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
do $$ declare t text; begin
  foreach t in array array['pur_companies','pur_departments','pur_profiles','pur_user_companies','pur_approval_rules',
    'pur_counters','pur_suppliers','pur_items','pur_master_requests','pur_requisitions','pur_pr_lines','pur_approvals',
    'pur_canvasses','pur_canvass_suppliers','pur_canvass_prices','pur_purchase_orders','pur_po_lines',
    'pur_receivings','pur_rr_lines','pur_activity'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop; end $$;

-- setup tables: readable by any active user, writable by Module Admin
create policy pur_companies_sel on public.pur_companies for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_companies_ins on public.pur_companies for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_companies_upd on public.pur_companies for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_departments_sel on public.pur_departments for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_departments_ins on public.pur_departments for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_departments_upd on public.pur_departments for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_departments_del on public.pur_departments for delete to authenticated using ((select public.pur_is_admin()));
create policy pur_profiles_sel on public.pur_profiles for select to authenticated using (user_id = (select auth.uid()) or (select public.pur_role()) is not null);
create policy pur_profiles_upd on public.pur_profiles for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_user_companies_sel on public.pur_user_companies for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_user_companies_ins on public.pur_user_companies for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_user_companies_del on public.pur_user_companies for delete to authenticated using ((select public.pur_is_admin()));
create policy pur_rules_sel on public.pur_approval_rules for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_rules_ins on public.pur_approval_rules for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_rules_upd on public.pur_approval_rules for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_rules_del on public.pur_approval_rules for delete to authenticated using ((select public.pur_is_admin()));

-- master data: everyone reads; only Module Admin writes directly. Others go through pur_master_request.
create policy pur_suppliers_sel on public.pur_suppliers for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_suppliers_ins on public.pur_suppliers for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_suppliers_upd on public.pur_suppliers for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_items_sel on public.pur_items for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_items_ins on public.pur_items for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_items_upd on public.pur_items for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_mr_sel on public.pur_master_requests for select to authenticated using (requested_by = (select auth.uid()) or (select public.pur_is_purch()));

-- PR
create policy pur_pr_sel on public.pur_requisitions for select to authenticated using (public.pur_can_view_pr(id));
create policy pur_pr_ins on public.pur_requisitions for insert to authenticated
  with check ((select public.pur_role()) in ('admin','purchasing','requester') and public.pur_has_company(company_id));
create policy pur_pr_upd on public.pur_requisitions for update to authenticated
  using (status in ('draft','rejected') and (requested_by = (select auth.uid()) or (select public.pur_is_purch())))
  with check (public.pur_has_company(company_id));
create policy pur_pr_del on public.pur_requisitions for delete to authenticated
  using (status = 'draft' and (requested_by = (select auth.uid()) or (select public.pur_is_purch())));
create policy pur_prl_sel on public.pur_pr_lines for select to authenticated using (public.pur_can_view_pr(pr_id));
create policy pur_prl_ins on public.pur_pr_lines for insert to authenticated with check (public.pur_pr_editable(pr_id));
create policy pur_prl_upd on public.pur_pr_lines for update to authenticated using (public.pur_pr_editable(pr_id)) with check (public.pur_pr_editable(pr_id));
create policy pur_prl_del on public.pur_pr_lines for delete to authenticated using (public.pur_pr_editable(pr_id));

-- approvals: read only
create policy pur_appr_sel on public.pur_approvals for select to authenticated
  using (approver_id = (select auth.uid()) or public.pur_has_company(company_id)
         or (doc_type = 'PR' and public.pur_can_view_pr(doc_id)));

-- canvass
create policy pur_cv_sel on public.pur_canvasses for select to authenticated using (public.pur_has_company(company_id));
create policy pur_cv_upd on public.pur_canvasses for update to authenticated using (public.pur_cv_editable(id)) with check ((select public.pur_is_purch()));
create policy pur_cs_sel on public.pur_canvass_suppliers for select to authenticated
  using (exists (select 1 from public.pur_canvasses c where c.id = canvass_id and public.pur_has_company(c.company_id)));
create policy pur_cs_ins on public.pur_canvass_suppliers for insert to authenticated with check (public.pur_cv_editable(canvass_id));
create policy pur_cs_upd on public.pur_canvass_suppliers for update to authenticated using (public.pur_cv_editable(canvass_id)) with check (public.pur_cv_editable(canvass_id));
create policy pur_cs_del on public.pur_canvass_suppliers for delete to authenticated using (public.pur_cv_editable(canvass_id));
create policy pur_cp_sel on public.pur_canvass_prices for select to authenticated
  using (exists (select 1 from public.pur_canvasses c where c.id = canvass_id and public.pur_has_company(c.company_id)));
create policy pur_cp_ins on public.pur_canvass_prices for insert to authenticated with check (public.pur_cv_editable(canvass_id));
create policy pur_cp_upd on public.pur_canvass_prices for update to authenticated using (public.pur_cv_editable(canvass_id)) with check (public.pur_cv_editable(canvass_id));
create policy pur_cp_del on public.pur_canvass_prices for delete to authenticated using (public.pur_cv_editable(canvass_id));

-- PO
create policy pur_po_sel on public.pur_purchase_orders for select to authenticated using (public.pur_can_view_po(id));
create policy pur_po_ins on public.pur_purchase_orders for insert to authenticated with check ((select public.pur_is_purch()));
create policy pur_po_upd on public.pur_purchase_orders for update to authenticated using (public.pur_po_editable(id)) with check ((select public.pur_is_purch()));
create policy pur_po_del on public.pur_purchase_orders for delete to authenticated using (status = 'draft' and (select public.pur_is_purch()));
create policy pur_pol_sel on public.pur_po_lines for select to authenticated using (public.pur_can_view_po(po_id));
create policy pur_pol_ins on public.pur_po_lines for insert to authenticated with check (public.pur_po_editable(po_id));
create policy pur_pol_upd on public.pur_po_lines for update to authenticated using (public.pur_po_editable(po_id)) with check (public.pur_po_editable(po_id));
create policy pur_pol_del on public.pur_po_lines for delete to authenticated using (public.pur_po_editable(po_id));

-- receiving: read only (writes via pur_receive)
create policy pur_rr_sel on public.pur_receivings for select to authenticated using (public.pur_has_company(company_id));
create policy pur_rrl_sel on public.pur_rr_lines for select to authenticated
  using (exists (select 1 from public.pur_receivings r where r.id = rr_id and public.pur_has_company(r.company_id)));

-- activity
create policy pur_act_sel on public.pur_activity for select to authenticated
  using ((select public.pur_role()) is not null and (company_id is null or public.pur_has_company(company_id) or public.pur_is_approver_of(doc_id)));

-- pur_counters: RLS on, no policies (by design)
