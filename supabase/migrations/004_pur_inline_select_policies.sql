-- INSERT ... RETURNING needs the SELECT policy to see the new row in the same statement,
-- so check the row's own columns instead of re-querying the table.
drop policy pur_pr_sel on public.pur_requisitions;
create policy pur_pr_sel on public.pur_requisitions for select to authenticated
  using (public.pur_has_company(company_id) or requested_by = (select auth.uid()) or public.pur_is_approver_of(id));
drop policy pur_po_sel on public.pur_purchase_orders;
create policy pur_po_sel on public.pur_purchase_orders for select to authenticated
  using (public.pur_has_company(company_id) or public.pur_is_approver_of(id));
