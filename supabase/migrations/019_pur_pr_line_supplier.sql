-- Each PR line can carry its own supplier, so a PR can be split into one PO per supplier
alter table public.pur_pr_lines add column if not exists supplier_id uuid references public.pur_suppliers(id) on delete set null;
create index if not exists pur_prl_sup_idx on public.pur_pr_lines(supplier_id);

-- supplier on a line must belong to the PR's module
create or replace function public.pur_tg_prl_supplier() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_doc text; v_sup text;
begin
  if new.supplier_id is null then return new; end if;
  select purchase_type into v_doc from public.pur_requisitions where id = new.pr_id;
  select purchase_type into v_sup from public.pur_suppliers where id = new.supplier_id;
  if v_sup is distinct from v_doc then raise exception 'Supplier on line "%" is not a % supplier.', new.description, v_doc; end if;
  return new;
end $$;
revoke all on function public.pur_tg_prl_supplier() from public, anon, authenticated;
drop trigger if exists pur_prl_supplier on public.pur_pr_lines;
create trigger pur_prl_supplier before insert or update of supplier_id on public.pur_pr_lines for each row execute function public.pur_tg_prl_supplier();

-- Purchasing assigns / changes line suppliers on an approved PR (lines not yet on a PO)
create or replace function public.pur_set_line_suppliers(p_pr uuid, p_map jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare r public.pur_requisitions; e record; v_n int := 0;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can assign suppliers.'; end if;
  select * into r from public.pur_requisitions where id = p_pr for update;
  perform public.pur_assert_type(r.purchase_type);
  if r.status not in ('approved','canvassing') then raise exception 'PR must be approved (current: %).', r.status; end if;
  for e in select key::uuid line_id, nullif(value #>> '{}','')::uuid sup from jsonb_each(coalesce(p_map,'{}'::jsonb)) loop
    if exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id
               where pl.pr_line_id = e.line_id and o.status <> 'cancelled') then continue; end if;
    update public.pur_pr_lines set supplier_id = e.sup where id = e.line_id and pr_id = p_pr;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.pur_set_line_suppliers(uuid, jsonb) from public, anon;
grant execute on function public.pur_set_line_suppliers(uuid, jsonb) to authenticated;

-- One click: create one draft PO per supplier from the PR's open lines (optionally only the given lines)
create or replace function public.pur_po_by_supplier(p_pr uuid, p_line_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare g record; v_po uuid; v_out jsonb := '[]'::jsonb; v_unassigned int;
begin
  if not public.pur_is_purch() then raise exception 'Only Purchasing can create POs.'; end if;
  select count(*) into v_unassigned from public.pur_pr_lines l
   where l.pr_id = p_pr and l.supplier_id is null and (p_line_ids is null or l.id = any(p_line_ids))
     and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id where pl.pr_line_id = l.id and o.status <> 'cancelled');
  if v_unassigned > 0 then raise exception '% selected line(s) have no supplier yet. Assign a supplier to every line first.', v_unassigned; end if;
  for g in select l.supplier_id, array_agg(l.id order by l.line_no) ids from public.pur_pr_lines l
            where l.pr_id = p_pr and l.supplier_id is not null and (p_line_ids is null or l.id = any(p_line_ids))
              and not exists (select 1 from public.pur_po_lines pl join public.pur_purchase_orders o on o.id = pl.po_id where pl.pr_line_id = l.id and o.status <> 'cancelled')
            group by l.supplier_id loop
    v_po := public.pur_po_from_pr(p_pr, g.supplier_id, g.ids);
    v_out := v_out || jsonb_build_object('po_id', v_po, 'po_no', (select po_no from public.pur_purchase_orders where id = v_po),
                                         'supplier', (select name from public.pur_suppliers where id = g.supplier_id), 'lines', array_length(g.ids,1));
  end loop;
  if jsonb_array_length(v_out) = 0 then raise exception 'No open lines to order.'; end if;
  return v_out;
end $$;
revoke execute on function public.pur_po_by_supplier(uuid, uuid[]) from public, anon;
grant execute on function public.pur_po_by_supplier(uuid, uuid[]) to authenticated;
