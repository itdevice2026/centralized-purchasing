-- Supplier price list: which supplier sells which item, at what price (aligns items to suppliers)
create table if not exists public.pur_supplier_items (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null references public.pur_suppliers(id) on delete cascade,
  item_id uuid not null references public.pur_items(id) on delete cascade,
  price numeric(14,4) not null default 0 check (price >= 0),
  price_basis text not null default 'VAT-INCLUSIVE' check (price_basis in ('VAT-INCLUSIVE','VAT-EXCLUSIVE','NON-VAT')),
  price_date date,
  remarks text default '',
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (supplier_id, item_id)
);
create index if not exists pur_si_item_idx on public.pur_supplier_items(item_id);
alter table public.pur_supplier_items enable row level security;
create policy pur_si_sel on public.pur_supplier_items for select to authenticated
  using ((select public.pur_role()) is not null
         and exists (select 1 from public.pur_suppliers s where s.id = supplier_id and public.pur_can_type(s.purchase_type)));
create policy pur_si_ins on public.pur_supplier_items for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_si_upd on public.pur_supplier_items for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_si_del on public.pur_supplier_items for delete to authenticated using ((select public.pur_is_admin()));

-- supplier and item must be in the same module
create or replace function public.pur_tg_si_type() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select purchase_type from public.pur_suppliers where id = new.supplier_id) is distinct from
     (select purchase_type from public.pur_items where id = new.item_id) then
    raise exception 'Supplier and item must be in the same module (Trade / Non-Trade).';
  end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.pur_tg_si_type() from public, anon, authenticated;
drop trigger if exists pur_si_type on public.pur_supplier_items;
create trigger pur_si_type before insert or update on public.pur_supplier_items for each row execute function public.pur_tg_si_type();

-- PO from PR: use the supplier's price-list price when there is one
create or replace function public.pur_po_from_pr(p_pr uuid, p_supplier uuid, p_line_ids uuid[] default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare r public.pur_requisitions; v_po uuid; v_vat text; v_svat text; v_terms text; v_n int; v_bad int; v_sel uuid[]; v_listed int;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can create a PO.'; end if;
  select * into r from public.pur_requisitions where id = p_pr for update;
  if r.id is null then raise exception 'PR not found.'; end if;
  perform public.pur_assert_type(r.purchase_type);
  if r.status not in ('approved','canvassing') then raise exception 'PR must be approved first (current: %).', r.status; end if;
  select vat_type, payment_terms into v_svat, v_terms
    from public.pur_suppliers where id = p_supplier and status = 'active' and purchase_type = r.purchase_type;
  if v_svat is null then raise exception 'Supplier is not an active % supplier.', r.purchase_type; end if;
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
  select count(*) into v_listed from public.pur_pr_lines l join public.pur_supplier_items si on si.item_id = l.item_id and si.supplier_id = p_supplier and si.active
   where l.id = any(v_sel);
  v_vat := case when v_svat = 'NON-VAT' then 'NON-VAT' when v_listed > 0 then 'VAT-INCLUSIVE' else 'VAT-EXCLUSIVE' end;
  perform set_config('pur.rpc','1', true);
  insert into public.pur_purchase_orders(company_id, supplier_id, pr_id, delivery_date, payment_terms, vat_type, created_by, status, delivery_address)
  values (r.company_id, p_supplier, p_pr, r.date_needed, coalesce(v_terms,''), v_vat, auth.uid(), 'draft',
          coalesce((select address from public.pur_companies where id = r.company_id),''))
  returning id into v_po;
  insert into public.pur_po_lines(po_id, line_no, pr_line_id, item_id, description, uom, qty, unit_price)
  select v_po, row_number() over (order by l.line_no), l.id, l.item_id, l.description, l.uom, l.qty,
         coalesce((select si.price from public.pur_supplier_items si where si.item_id = l.item_id and si.supplier_id = p_supplier and si.active), l.est_unit_cost)
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
