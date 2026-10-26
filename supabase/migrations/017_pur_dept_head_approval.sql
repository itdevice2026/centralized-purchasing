-- Department Head approval: every PR is first approved by the head of the requester's department
alter table public.pur_departments add column if not exists head_id uuid references public.pur_profiles(user_id) on delete set null;
create index if not exists pur_dept_head_idx on public.pur_departments(head_id);

create or replace function public.pur_submit(p_doc_type text, p_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_company uuid; v_total numeric; v_status text; v_owner uuid; v_no text; v_round int; v_steps int; v_ptype text;
        v_dept uuid; v_dept_name text; v_head uuid; v_head_ok boolean;
begin
  if p_doc_type = 'PR' then
    select company_id, total, status, requested_by, pr_no, purchase_type, department_id
      into v_company, v_total, v_status, v_owner, v_no, v_ptype, v_dept
      from public.pur_requisitions where id = p_id for update;
    if v_company is null then raise exception 'PR not found.'; end if;
    perform public.pur_assert_type(v_ptype);
    if v_owner <> auth.uid() and not public.pur_is_purch() then raise exception 'Only the requester or Purchasing can submit this PR.'; end if;
    if not exists (select 1 from public.pur_pr_lines where pr_id = p_id) then raise exception 'Add at least one item line before submitting.'; end if;
    if exists (select 1 from public.pur_pr_lines l join public.pur_items i on i.id = l.item_id
               where l.pr_id = p_id and i.purchase_type <> v_ptype) then
      raise exception 'Some items are not in the % Item Master.', v_ptype; end if;
    if v_dept is null then raise exception 'Select the Department before submitting — the PR goes to the Department Head first.'; end if;
    select d.name, d.head_id, coalesce(p.active, false) into v_dept_name, v_head, v_head_ok
      from public.pur_departments d left join public.pur_profiles p on p.user_id = d.head_id where d.id = v_dept;
    if v_head is null or not v_head_ok then
      raise exception 'No active Department Head is set for the % department. Ask the Module Admin to assign one in Setup → Departments.', v_dept_name; end if;
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

  -- Step 0: Department Head (PR only; skipped when the requester is the head)
  if p_doc_type = 'PR' and v_head <> v_owner then
    insert into public.pur_approvals(doc_type, doc_id, company_id, round, step_no, step_name, approver_id)
    values ('PR', p_id, v_company, v_round, 0, 'Department Head (' || v_dept_name || ')', v_head);
  end if;

  -- Matrix steps (by company, document, purchase type and amount)
  insert into public.pur_approvals(doc_type, doc_id, company_id, round, step_no, step_name, approver_id)
  select distinct on (r.step_no, r.approver_id) p_doc_type, p_id, v_company, v_round, r.step_no, r.step_name, r.approver_id
    from public.pur_approval_rules r
    join public.pur_profiles p on p.user_id = r.approver_id and p.active
   where r.company_id = v_company and r.doc_type = p_doc_type and r.purchase_type in ('All', v_ptype)
     and r.min_amount <= v_total
   order by r.step_no, r.approver_id, (r.purchase_type = 'All');

  select count(*) into v_steps from public.pur_approvals where doc_id = p_id and round = v_round;
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
