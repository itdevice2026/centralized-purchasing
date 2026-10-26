-- Allowed company email domains for new logins (managed by the Purchasing Module Admin)
create table if not exists public.pur_email_domains (
  domain text primary key check (domain = lower(btrim(domain)) and domain like '%.%' and domain not like '%@%'),
  company_code text default '',
  note text default '',
  created_at timestamptz not null default now()
);
alter table public.pur_email_domains enable row level security;
create policy pur_dom_sel on public.pur_email_domains for select to authenticated using ((select public.pur_role()) is not null);
create policy pur_dom_ins on public.pur_email_domains for insert to authenticated with check ((select public.pur_is_admin()));
create policy pur_dom_upd on public.pur_email_domains for update to authenticated using ((select public.pur_is_admin())) with check ((select public.pur_is_admin()));
create policy pur_dom_del on public.pur_email_domains for delete to authenticated using ((select public.pur_is_admin()));

insert into public.pur_email_domains(domain, note) values
  ('meatplus.ph','Meatplus group'), ('pacificmeat.ph','Pacific Meat'), ('pacifics.ph','Pacific group'), ('foodsolutions.ph','FoodSolutions')
on conflict do nothing;

-- Shared sign-up guard (used by all apps in this project): same rules as before + the domains above
create or replace function public.fp_enforce_company_email()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if NEW.email is null then
    raise exception 'An email address is required';
  end if;
  if lower(NEW.email) like '%@meatplus.ph' then
    return NEW;
  end if;
  if exists (select 1 from public.pur_email_domains d where lower(split_part(NEW.email,'@',2)) = d.domain) then
    return NEW;
  end if;
  -- allow the employee's own (personal) email address on file
  if exists (select 1 from public.hris_employees e where lower(e.email) = lower(NEW.email)) then
    return NEW;
  end if;
  raise exception 'Sign-up restricted to @meatplus.ph addresses, or an email already on file in the employee masterfile';
end;
$function$;

-- Module Admin: check an email before creating access
create or replace function public.pur_email_status(p_email text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_e text := lower(btrim(coalesce(p_email,''))); v_uid uuid;
begin
  if not public.pur_is_admin() then raise exception 'Module Admin only.'; end if;
  select id into v_uid from auth.users where lower(email) = v_e limit 1;
  return jsonb_build_object(
    'valid', v_e ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$',
    'exists', v_uid is not null,
    'in_purchasing', exists (select 1 from public.pur_profiles where user_id = v_uid),
    'last_sign_in', (select last_sign_in_at from auth.users where id = v_uid),
    'domain_allowed', v_e like '%@meatplus.ph'
        or exists (select 1 from public.pur_email_domains d where split_part(v_e,'@',2) = d.domain)
        or exists (select 1 from public.hris_employees e where lower(e.email) = v_e));
end $$;
revoke execute on function public.pur_email_status(text) from public, anon;
grant execute on function public.pur_email_status(text) to authenticated;
