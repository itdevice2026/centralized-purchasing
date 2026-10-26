-- President / Executive: no direct document access; everything comes through pur_exec_summary
create or replace function public.pur_has_company(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch()
      or coalesce((select role = 'accounting' from public.pur_profiles where user_id = auth.uid() and active), false)
      or exists (select 1 from public.pur_user_companies uc
                   join public.pur_profiles p on p.user_id = uc.user_id and p.active
                  where uc.user_id = auth.uid() and uc.company_id = p_company
                    and p.role <> 'executive')
$$;
