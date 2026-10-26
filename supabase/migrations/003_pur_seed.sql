-- Seed: the 6 group companies (copied from hrf_companies incl. logos) + Module Admins + starter departments
insert into public.pur_companies(code, name, address, logo)
select code, name, coalesce(address,''), logo from public.hrf_companies
on conflict (code) do nothing;

insert into public.pur_profiles(user_id, email, full_name, role)
select id, email, coalesce(raw_user_meta_data->>'full_name', split_part(email,'@',1)), 'admin'
  from auth.users where lower(email) in ('nomer.staana@meatplus.ph','itdevice@meatplus.ph')
on conflict (user_id) do update set role = 'admin', active = true;

insert into public.pur_departments(company_id, name)
select c.id, d.name from public.pur_companies c
cross join (values ('Accounting'),('Admin'),('HR'),('IT'),('Operations'),('Purchasing'),('Sales'),('Warehouse')) d(name)
on conflict do nothing;
