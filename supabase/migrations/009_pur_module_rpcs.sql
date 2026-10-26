-- Workflow RPCs enforce module (Trade / Non-Trade) access; receiving gets module numbering.
alter table public.pur_suppliers add column if not exists purchase_type text not null default 'Non-Trade'
  check (purchase_type in ('Trade','Non-Trade'));
create index if not exists pur_sup_type_idx on public.pur_suppliers(purchase_type);
create or replace function public.pur_submit(p_doc_type text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_company uuid; v_total numeric; v_status text; v_owner uuid; v_no text; v_round int; v_steps int; v_ptype text;
begin
  if p_doc_type = 'PR' then
    select company_id, total, status, requested_by, pr_no, purchase_type into v_company, v_total, v_status, v_owner, v_no, v_ptype
      from public.pur_requisitions where id = p_id for update;
    if v_company is null then raise exception 'PR not found.'; end if;
    perform public.pur_assert_type(v_ptype);
    if v_owner <> auth.uid() and not public.pur_is_purch() then raise exception 'Only the requester or Purchasing can submit this PR.'; end if;
    if not exists (select 1 from public.pur_pr_lines where pr_id = p_id) then raise exception 'Add at least one item line before submitting.'; end if;
    if exists (select 1 from public.pur_pr_lines l join public.pur_items i on i.id = l.item_id
               where l.pr_id = p_id and i.purchase_type not in ('Both', v_ptype)) then
      raise exception 'Some items are not allowed for a % purchase. Check the item purchase type.', v_ptype; end if;
  elsif p_doc_type = 'PO' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can submit a PO.'; end if;
    select company_id, total, status, po_no, purchase_type into v_company, v_total, v_status, v_no, v_ptype
      from public.pur_purchase_orders where id = p_id for update;
    if v_company is null then raise exception 'PO not found.'; end if;
    perform public.pur_assert_type(v_ptype);
    if not exists (select 1 from public.pur_po_lines where po_id = p_id) then raise exception 'Add at least one item line before submitting.'; end if;
    if exists (select 1 from public.pur_purchase_orders o join public.pur_suppliers s on s.id = o.supplier_id
               where o.id = p_id and (s.purchase_type <> v_ptype or s.status <> 'active')) then
      raise exception 'The supplier is not an active % supplier.', v_ptype; end if;
  else
    raise exception 'Unknown document type.';
  end if;
  if v_status not in ('draft','rejected') then raise exception '% is already %.', v_no, v_status; end if;
  select coalesce(max(round),0) + 1 into v_round from public.pur_approvals where doc_id = p_id;
  insert into public.pur_approvals(doc_type, doc_id, company_id, round, step_no, step_name, approver_id)
  select distinct on (r.step_no, r.approver_id) p_doc_type, p_id, v_company, v_round, r.step_no, r.step_name, r.approver_id
    from public.pur_approval_rules r
    join public.pur_profiles p on p.user_id = r.approver_id and p.active
   where r.company_id = v_company and r.doc_type = p_doc_type and r.purchase_type in ('All', v_ptype)
     and r.min_amount <= v_total
   order by r.step_no, r.approver_id, (r.purchase_type = 'All');
  get diagnostics v_steps = row_count;
  if v_steps = 0 then
    raise exception 'No approvers are set up for % (%) of this company. Ask the Module Admin to configure the Approval Matrix.', p_doc_type, v_ptype;
  end if;
  perform set_config('pur.rpc','1', true);
  if p_doc_type = 'PR' then
    update public.pur_requisitions set status = 'pending', submitted_at = now() where id = p_id;
  else
    update public.pur_purchase_orders set status = 'pending', submitted_at = now() where id = p_id;
  end if;
  perform public.pur_log(p_doc_type, p_id, v_company, 'submitted', v_ptype || ' · Amount ' || to_char(v_total,'FM999,999,999,990.00'));
  return 'pending';
end $$;

create or replace function public.pur_cancel(p_doc_type text, p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_owner uuid; v_company uuid; v_ptype text;
begin
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Please give a reason for cancelling.'; end if;
  perform set_config('pur.rpc','1', true);
  if p_doc_type = 'PR' then
    select status, requested_by, company_id, purchase_type into v_status, v_owner, v_company, v_ptype from public.pur_requisitions where id = p_id for update;
    if not (v_owner = auth.uid() or (public.pur_is_purch() and public.pur_can_type(v_ptype))) then raise exception 'Not allowed.'; end if;
    if v_status not in ('draft','pending','rejected','approved','canvassing') then raise exception 'PR is % and cannot be cancelled.', v_status; end if;
    if exists (select 1 from public.pur_purchase_orders where pr_id = p_id and status <> 'cancelled') then
      raise exception 'Cancel the POs of this PR first.'; end if;
    update public.pur_requisitions set status = 'cancelled' where id = p_id;
    update public.pur_canvasses set status = 'cancelled' where pr_id = p_id and status = 'draft';
  elsif p_doc_type = 'PO' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can cancel a PO.'; end if;
    select status, company_id, purchase_type into v_status, v_company, v_ptype from public.pur_purchase_orders where id = p_id for update;
    perform public.pur_assert_type(v_ptype);
    if v_status in ('partial','received','closed','cancelled') then raise exception 'PO is % and cannot be cancelled.', v_status; end if;
    update public.pur_purchase_orders set status = 'cancelled' where id = p_id;
    update public.pur_requisitions r set status = 'approved'
     where r.id = (select pr_id from public.pur_purchase_orders where id = p_id) and r.status = 'ordered'
       and not exists (select 1 from public.pur_purchase_orders o where o.pr_id = r.id and o.status <> 'cancelled');
  elsif p_doc_type = 'CV' then
    if not public.pur_is_purch() then raise exception 'Only Purchasing can cancel a canvass.'; end if;
    select status, company_id, purchase_type into v_status, v_company, v_ptype from public.pur_canvasses where id = p_id for update;
    perform public.pur_assert_type(v_ptype);
    if v_status <> 'draft' then raise exception 'Only a draft canvass can be cancelled.'; end if;
    update public.pur_canvasses set status = 'cancelled' where id = p_id;
    update public.pur_requisitions r set status = 'approved'
     where r.id = (select pr_id from public.pur_canvasses where id = p_id) and r.status = 'canvassing';
  else raise exception 'Unknown document type.';
  end if;
  update public.pur_approvals set status = 'skipped', acted_at = now() where doc_id = p_id and status = 'pending';
  perform public.pur_log(p_doc_type, p_id, v_company, 'cancelled', p_reason);
end $$;

create or replace function public.pur_start_canvass(p_pr uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_company uuid; v_id uuid; v_ptype text;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can canvass.'; end if;
  select status, company_id, purchase_type into v_status, v_company, v_ptype from public.pur_requisitions where id = p_pr for update;
  perform public.pur_assert_type(v_ptype);
  if v_status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', v_status; end if;
  select id into v_id from public.pur_canvasses where pr_id = p_pr and status = 'draft' limit 1;
  if v_id is not null then return v_id; end if;
  insert into public.pur_canvasses(pr_id, company_id, created_by) values (p_pr, v_company, auth.uid()) returning id into v_id;
  perform set_config('pur.rpc','1', true);
  update public.pur_requisitions set status = 'canvassing' where id = p_pr;
  perform public.pur_log('CV', v_id, v_company, 'created', '');
  return v_id;
end $$;

create or replace function public.pur_award_canvass(p_cv uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare c public.pur_canvasses; v_missing int; v_multi int; s record; v_po uuid; v_count int := 0; v_pr record;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can award a canvass.'; end if;
  select * into c from public.pur_canvasses where id = p_cv for update;
  perform public.pur_assert_type(c.purchase_type);
  if c.status <> 'draft' then raise exception 'Canvass is already %.', c.status; end if;
  if exists (select 1 from public.pur_canvass_suppliers cs join public.pur_suppliers sp on sp.id = cs.supplier_id
             where cs.canvass_id = p_cv and (sp.purchase_type <> c.purchase_type or sp.status <> 'active')) then
    raise exception 'All canvassed suppliers must be active % suppliers.', c.purchase_type; end if;
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

create or replace function public.pur_po_from_pr(p_pr uuid, p_supplier uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.pur_requisitions; v_po uuid; v_vat text; v_terms text;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can create a PO.'; end if;
  select * into r from public.pur_requisitions where id = p_pr for update;
  perform public.pur_assert_type(r.purchase_type);
  if r.status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', r.status; end if;
  select case when vat_type = 'NON-VAT' then 'NON-VAT' else 'VAT-EXCLUSIVE' end, payment_terms into v_vat, v_terms
    from public.pur_suppliers where id = p_supplier and status = 'active' and purchase_type = r.purchase_type;
  if v_vat is null then raise exception 'Supplier is not an active % supplier.', r.purchase_type; end if;
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
declare v_status text; v_company uuid; v_ptype text;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can do this.'; end if;
  select status, company_id, purchase_type into v_status, v_company, v_ptype from public.pur_purchase_orders where id = p_po for update;
  perform public.pur_assert_type(v_ptype);
  if v_status <> 'approved' then raise exception 'Only an approved PO can be marked as sent.'; end if;
  perform set_config('pur.rpc','1', true);
  update public.pur_purchase_orders set status = 'sent' where id = p_po;
  perform public.pur_log('PO', p_po, v_company, 'sent to supplier', '');
end $$;

create or replace function public.pur_receive(p_po uuid, p_received_date date, p_dr_no text, p_invoice_no text, p_remarks text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare o public.pur_purchase_orders; v_rr uuid; l jsonb; pl public.pur_po_lines; v_q numeric; v_rej numeric; v_open int; v_any boolean := false;
begin
  select * into o from public.pur_purchase_orders where id = p_po for update;
  if o.id is null then raise exception 'PO not found.'; end if;
  if coalesce(public.pur_role(),'') not in ('admin','purchasing','receiver') or not public.pur_has_company(o.company_id) then
    raise exception 'You are not allowed to receive for this company.'; end if;
  perform public.pur_assert_type(o.purchase_type);
  if o.status not in ('approved','sent','partial') then raise exception 'PO is % and cannot be received.', o.status; end if;
  insert into public.pur_receivings(rr_no, po_id, company_id, purchase_type, received_by, received_date, dr_no, invoice_no, remarks)
  values (public.pur_next_no('RR-' || public.pur_tcode(o.purchase_type), o.company_id), p_po, o.company_id, o.purchase_type, auth.uid(),
          coalesce(p_received_date, current_date), coalesce(p_dr_no,''), coalesce(p_invoice_no,''), coalesce(p_remarks,''))
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
  update public.pur_requisitions r set status = 'closed'
   where r.id = o.pr_id and r.status = 'ordered'
     and not exists (select 1 from public.pur_purchase_orders x where x.pr_id = r.id and x.status not in ('received','closed','cancelled'));
  perform public.pur_log('PO', p_po, o.company_id, 'received', (select rr_no from public.pur_receivings where id = v_rr));
  return v_rr;
end $$;
