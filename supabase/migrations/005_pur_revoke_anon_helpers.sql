revoke execute on function public.pur_role(), public.pur_is_admin(), public.pur_is_purch(), public.pur_has_company(uuid),
  public.pur_is_approver_of(uuid), public.pur_can_view_pr(uuid), public.pur_can_view_po(uuid), public.pur_pr_editable(uuid),
  public.pur_po_editable(uuid), public.pur_cv_editable(uuid) from public, anon;
grant execute on function public.pur_role(), public.pur_is_admin(), public.pur_is_purch(), public.pur_has_company(uuid),
  public.pur_is_approver_of(uuid), public.pur_can_view_pr(uuid), public.pur_can_view_po(uuid), public.pur_pr_editable(uuid),
  public.pur_po_editable(uuid), public.pur_cv_editable(uuid) to authenticated;
