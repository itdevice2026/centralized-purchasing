-- "Call" a PR into a PO: choose which PR lines go to which supplier (split a PR across several POs)
-- A PR becomes 'ordered' only when every one of its lines is on a live (non-cancelled) PO.

create or replace function public.pur_pr_open_lines(p_pr uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.pur_pr_lines l
   where l.pr_id = p_pr
     and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id
                      where pl.pr_line_id = l.id and o.status <> 'cancelled')
$$;
revoke all on function public.pur_pr_open_lines(uuid) from public, anon;
grant execute on function public.pur_pr_open_lines(uuid) to authenticated;

drop function if exists public.pur_po_from_pr(uuid, uuid);
create or replace function public.pur_po_from_pr(p_pr uuid, p_supplier uuid, p_line_ids uuid[] default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.pur_requisitions; v_po uuid; v_vat text; v_terms text; v_n int; v_bad int; v_sel uuid[];
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can create a PO.'; end if;
  select * into r from public.pur_requisitions where id = p_pr for update;
  if r.id is null then raise exception 'PR not found.'; end if;
  perform public.pur_assert_type(r.purchase_type);
  if r.status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', r.status; end if;
  select case when vat_type = 'NON-VAT' then 'NON-VAT' else 'VAT-EXCLUSIVE' end, payment_terms into v_vat, v_terms
    from public.pur_suppliers where id = p_supplier and status = 'active' and purchase_type = r.purchase_type;
  if v_vat is null then raise exception 'Supplier is not an active % supplier.', r.purchase_type; end if;

  -- lines to order: the selected ones, or all lines not yet on a live PO
  v_sel := array(select l.id from public.pur_pr_lines l
   where l.pr_id = p_pr and (p_line_ids is null or l.id = any(p_line_ids))
     and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id
                      where pl.pr_line_id = l.id and o.status <> 'cancelled'));
  v_n := coalesce(array_length(v_sel, 1), 0);
  if p_line_ids is not null then
    select count(*) into v_bad from unnest(p_line_ids) x(id) where not (x.id = any(v_sel));
    if v_bad > 0 then raise exception '% selected line(s) are already on another PO or do not belong to this PR.', v_bad; end if;
  end if;
  if v_n = 0 then raise exception 'All lines of % are already on a PO.', r.pr_no; end if;

  perform set_config('pur.rpc','1', true);
  insert into public.pur_purchase_orders(company_id, supplier_id, pr_id, delivery_date, payment_terms, vat_type, created_by, status, delivery_address)
  values (r.company_id, p_supplier, p_pr, r.date_needed, coalesce(v_terms,''), v_vat, auth.uid(), 'draft',
          coalesce((select address from public.pur_companies where id = r.company_id),''))
  returning id into v_po;
  insert into public.pur_po_lines(po_id, line_no, pr_line_id, item_id, description, uom, qty, unit_price)
  select v_po, row_number() over (order by l.line_no), l.id, l.item_id, l.description, l.uom, l.qty, l.est_unit_cost
    from public.pur_pr_lines l where l.id = any(v_sel);
  if public.pur_pr_open_lines(p_pr) = 0 then
    update public.pur_canvasses set status = 'cancelled' where pr_id = p_pr and status = 'draft';
    update public.pur_requisitions set status = 'ordered' where id = p_pr;
  end if;
  perform public.pur_log('PO', v_po, r.company_id, 'created from PR', r.pr_no || ' · ' || v_n || ' line(s)');
  perform public.pur_log('PR', p_pr, r.company_id, 'called to PO', (select po_no from public.pur_purchase_orders where id = v_po) || ' · ' || v_n || ' line(s)');
  return v_po;
end $$;
revoke execute on function public.pur_po_from_pr(uuid, uuid, uuid[]) from public, anon;
grant execute on function public.pur_po_from_pr(uuid, uuid, uuid[]) to authenticated;

-- Canvass award only orders lines that are not yet on a PO
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
  -- open lines = PR lines not yet on a live PO
  select count(*) into v_missing from public.pur_pr_lines l
   where l.pr_id = c.pr_id
     and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id where pl.pr_line_id = l.id and o.status <> 'cancelled')
     and not exists (select 1 from public.pur_canvass_prices p where p.canvass_id = p_cv and p.pr_line_id = l.id and p.awarded);
  if v_missing > 0 then raise exception '% open PR line(s) have no awarded supplier.', v_missing; end if;
  select count(*) into v_multi from (select pr_line_id from public.pur_canvass_prices where canvass_id = p_cv and awarded group by pr_line_id having count(*) > 1) x;
  if v_multi > 0 then raise exception 'Each PR line can be awarded to only one supplier.'; end if;
  select * into v_pr from public.pur_requisitions where id = c.pr_id;
  perform set_config('pur.rpc','1', true);
  update public.pur_canvasses set status = 'awarded', awarded_at = now() where id = p_cv;
  for s in select cs.id cs_id, cs.supplier_id, cs.payment_terms, sp.vat_type
             from public.pur_canvass_suppliers cs join public.pur_suppliers sp on sp.id = cs.supplier_id
            where cs.canvass_id = p_cv
              and exists (select 1 from public.pur_canvass_prices p join public.pur_pr_lines l on l.id = p.pr_line_id
                           where p.cs_id = cs.id and p.awarded
                             and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id where pl.pr_line_id = l.id and o.status <> 'cancelled')) loop
    insert into public.pur_purchase_orders(company_id, supplier_id, pr_id, canvass_id, delivery_date, payment_terms, vat_type, created_by, status, delivery_address)
    values (c.company_id, s.supplier_id, c.pr_id, p_cv, v_pr.date_needed, coalesce(s.payment_terms,''),
            case when s.vat_type = 'NON-VAT' then 'NON-VAT' else 'VAT-EXCLUSIVE' end, auth.uid(), 'draft',
            coalesce((select address from public.pur_companies where id = c.company_id),''))
    returning id into v_po;
    insert into public.pur_po_lines(po_id, line_no, pr_line_id, item_id, description, uom, qty, unit_price)
    select v_po, row_number() over (order by l.line_no), l.id, l.item_id, l.description, l.uom, l.qty, p.unit_price
      from public.pur_canvass_prices p join public.pur_pr_lines l on l.id = p.pr_line_id
     where p.cs_id = s.cs_id and p.awarded
       and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id
                        where pl.pr_line_id = l.id and o.status <> 'cancelled' and o.id <> v_po);
    perform public.pur_log('PO', v_po, c.company_id, 'created from canvass', c.cv_no);
    v_count := v_count + 1;
  end loop;
  if public.pur_pr_open_lines(c.pr_id) = 0 then
    update public.pur_requisitions set status = 'ordered' where id = c.pr_id;
  else
    update public.pur_requisitions set status = 'approved' where id = c.pr_id and status = 'canvassing';
  end if;
  perform public.pur_log('CV', p_cv, c.company_id, 'awarded', v_count || ' PO(s) generated');
  return v_count;
end $$;

-- Cancelling a PO re-opens its PR lines for ordering
create or replace function public.pur_cancel(p_doc_type text, p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_status text; v_owner uuid; v_company uuid; v_ptype text; v_pr uuid;
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
    select status, company_id, purchase_type, pr_id into v_status, v_company, v_ptype, v_pr from public.pur_purchase_orders where id = p_id for update;
    perform public.pur_assert_type(v_ptype);
    if v_status in ('partial','received','closed','cancelled') then raise exception 'PO is % and cannot be cancelled.', v_status; end if;
    update public.pur_purchase_orders set status = 'cancelled' where id = p_id;
    if v_pr is not null and public.pur_pr_open_lines(v_pr) > 0 then
      update public.pur_requisitions set status = 'approved' where id = v_pr and status = 'ordered';
    end if;
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
