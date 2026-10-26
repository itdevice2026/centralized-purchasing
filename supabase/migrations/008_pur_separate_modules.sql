-- =====================================================================
-- Separate Trade and Non-Trade modules
--  * per-user module access (Both / Trade / Non-Trade)
--  * separate document series: PR-T-MTC-2026-00001 / PR-N-..., PO-T/N, CV-T/N, RR-T/N
--  * purchase type fixed once a document is created
--  * RLS + RPCs enforce module access (approvers still see what they must approve)
-- =====================================================================
alter table public.pur_profiles add column if not exists module_access text not null default 'Both'
  check (module_access in ('Both','Trade','Non-Trade'));
alter table public.pur_canvasses add column if not exists purchase_type text not null default 'Non-Trade'
  check (purchase_type in ('Trade','Non-Trade'));
alter table public.pur_receivings add column if not exists purchase_type text not null default 'Non-Trade'
  check (purchase_type in ('Trade','Non-Trade'));
create index if not exists pur_cv_type_idx on public.pur_canvasses(purchase_type);
create index if not exists pur_rr_type_idx on public.pur_receivings(purchase_type);

create or replace function public.pur_tcode(t text) returns text
language sql immutable set search_path = '' as $$ select case when t = 'Trade' then 'T' else 'N' end $$;

create or replace function public.pur_can_type(t text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'admin' or module_access in ('Both', t)
                     from public.pur_profiles where user_id = auth.uid() and active), false)
$$;
revoke execute on function public.pur_can_type(text) from public, anon;
grant execute on function public.pur_can_type(text) to authenticated;

create or replace function public.pur_assert_type(t text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.pur_can_type(t) then raise exception 'You have no access to the % Purchasing module.', t; end if;
end $$;
revoke all on function public.pur_assert_type(text) from public, anon, authenticated;

-- ---------- triggers: numbering by module, type locked ----------
create or replace function public.pur_tg_pr_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.pr_no := public.pur_next_no('PR-' || public.pur_tcode(new.purchase_type), new.company_id);
    new.status := 'draft';
    new.total := 0;
    if not public.pur_is_purch() then new.requested_by := auth.uid(); end if;
  else
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then
      if new.status is distinct from old.status or new.pr_no is distinct from old.pr_no
         or new.company_id is distinct from old.company_id or new.requested_by is distinct from old.requested_by
         or new.purchase_type is distinct from old.purchase_type then
        raise exception 'Status / number / company / purchase type can only be changed through the workflow.';
      end if;
      if old.status not in ('draft','rejected') then
        raise exception 'PR % is % and can no longer be edited.', old.pr_no, old.status;
      end if;
    end if;
    new.updated_at := now();
  end if;
  return new;
end $$;

drop trigger if exists pur_po_type on public.pur_purchase_orders;
drop function if exists public.pur_tg_po_type();

create or replace function public.pur_tg_po_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_sum numeric;
begin
  if tg_op = 'INSERT' then
    if new.pr_id is not null then
      select purchase_type into new.purchase_type from public.pur_requisitions where id = new.pr_id;
    end if;
    new.po_no := public.pur_next_no('PO-' || public.pur_tcode(new.purchase_type), new.company_id);
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then new.status := 'draft'; end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
  else
    if coalesce(current_setting('pur.rpc', true),'') <> '1' then
      if new.status is distinct from old.status or new.po_no is distinct from old.po_no
         or new.company_id is distinct from old.company_id or new.purchase_type is distinct from old.purchase_type
         or new.pr_id is distinct from old.pr_id then
        raise exception 'Status / number / company / purchase type can only be changed through the workflow.';
      end if;
      if old.status not in ('draft','rejected') then
        raise exception 'PO % is % and can no longer be edited.', old.po_no, old.status;
      end if;
    end if;
    new.updated_at := now();
  end if;
  select coalesce(sum(amount),0) into v_sum from public.pur_po_lines where po_id = new.id;
  if new.vat_type = 'VAT-EXCLUSIVE' then
    new.subtotal := v_sum; new.vat_amount := round(v_sum * 0.12, 2); new.total := new.subtotal + new.vat_amount;
  elsif new.vat_type = 'VAT-INCLUSIVE' then
    new.total := v_sum; new.vat_amount := round(v_sum * 12 / 112, 2); new.subtotal := new.total - new.vat_amount;
  else
    new.subtotal := v_sum; new.vat_amount := 0; new.total := v_sum;
  end if;
  return new;
end $$;

create or replace function public.pur_tg_cv_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    select company_id, purchase_type into new.company_id, new.purchase_type from public.pur_requisitions where id = new.pr_id;
    new.cv_no := public.pur_next_no('CV-' || public.pur_tcode(new.purchase_type), new.company_id);
    new.status := 'draft';
    new.created_by := coalesce(auth.uid(), new.created_by);
  elsif coalesce(current_setting('pur.rpc', true),'') <> '1' then
    if new.status is distinct from old.status or new.pr_id is distinct from old.pr_id
       or new.purchase_type is distinct from old.purchase_type then
      raise exception 'Canvass status can only be changed through the workflow.';
    end if;
    if old.status <> 'draft' then raise exception 'Canvass % is % and can no longer be edited.', old.cv_no, old.status; end if;
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_pr_before(), public.pur_tg_po_before(), public.pur_tg_cv_before() from public, anon, authenticated;

-- ---------- visibility helpers include module access ----------
create or replace function public.pur_can_view_pr(p_pr uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_requisitions r where r.id = p_pr
                  and ((public.pur_has_company(r.company_id) and public.pur_can_type(r.purchase_type))
                       or r.requested_by = auth.uid() or public.pur_is_approver_of(r.id)))
$$;
create or replace function public.pur_can_view_po(p_po uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_purchase_orders o where o.id = p_po
                  and ((public.pur_has_company(o.company_id) and public.pur_can_type(o.purchase_type))
                       or public.pur_is_approver_of(o.id)))
$$;
create or replace function public.pur_pr_editable(p_pr uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pur_requisitions r where r.id = p_pr
                  and r.status in ('draft','rejected') and public.pur_can_type(r.purchase_type)
                  and (r.requested_by = auth.uid() or public.pur_is_purch()))
$$;
create or replace function public.pur_po_editable(p_po uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch() and exists (select 1 from public.pur_purchase_orders o
                  where o.id = p_po and o.status in ('draft','rejected') and public.pur_can_type(o.purchase_type))
$$;
create or replace function public.pur_cv_editable(p_cv uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.pur_is_purch() and exists (select 1 from public.pur_canvasses c
                  where c.id = p_cv and c.status = 'draft' and public.pur_can_type(c.purchase_type))
$$;

-- ---------- policies ----------
drop policy if exists pur_pr_sel on public.pur_requisitions;
create policy pur_pr_sel on public.pur_requisitions for select to authenticated
  using ((public.pur_has_company(company_id) and public.pur_can_type(purchase_type))
         or requested_by = (select auth.uid()) or public.pur_is_approver_of(id));
drop policy if exists pur_pr_ins on public.pur_requisitions;
create policy pur_pr_ins on public.pur_requisitions for insert to authenticated
  with check ((select public.pur_role()) in ('admin','purchasing','requester')
              and public.pur_has_company(company_id) and public.pur_can_type(purchase_type));
drop policy if exists pur_pr_upd on public.pur_requisitions;
create policy pur_pr_upd on public.pur_requisitions for update to authenticated
  using (status in ('draft','rejected') and public.pur_can_type(purchase_type)
         and (requested_by = (select auth.uid()) or (select public.pur_is_purch())))
  with check (public.pur_has_company(company_id));

drop policy if exists pur_po_sel on public.pur_purchase_orders;
create policy pur_po_sel on public.pur_purchase_orders for select to authenticated
  using ((public.pur_has_company(company_id) and public.pur_can_type(purchase_type)) or public.pur_is_approver_of(id));
drop policy if exists pur_po_ins on public.pur_purchase_orders;
create policy pur_po_ins on public.pur_purchase_orders for insert to authenticated
  with check ((select public.pur_is_purch()) and public.pur_can_type(purchase_type));
drop policy if exists pur_po_del on public.pur_purchase_orders;
create policy pur_po_del on public.pur_purchase_orders for delete to authenticated
  using (status = 'draft' and (select public.pur_is_purch()) and public.pur_can_type(purchase_type));

drop policy if exists pur_cv_sel on public.pur_canvasses;
create policy pur_cv_sel on public.pur_canvasses for select to authenticated
  using (public.pur_has_company(company_id) and public.pur_can_type(purchase_type));
drop policy if exists pur_cs_sel on public.pur_canvass_suppliers;
create policy pur_cs_sel on public.pur_canvass_suppliers for select to authenticated
  using (exists (select 1 from public.pur_canvasses c where c.id = canvass_id
                  and public.pur_has_company(c.company_id) and public.pur_can_type(c.purchase_type)));
drop policy if exists pur_cp_sel on public.pur_canvass_prices;
create policy pur_cp_sel on public.pur_canvass_prices for select to authenticated
  using (exists (select 1 from public.pur_canvasses c where c.id = canvass_id
                  and public.pur_has_company(c.company_id) and public.pur_can_type(c.purchase_type)));

drop policy if exists pur_rr_sel on public.pur_receivings;
create policy pur_rr_sel on public.pur_receivings for select to authenticated
  using (public.pur_has_company(company_id) and public.pur_can_type(purchase_type));
drop policy if exists pur_rrl_sel on public.pur_rr_lines;
create policy pur_rrl_sel on public.pur_rr_lines for select to authenticated
  using (exists (select 1 from public.pur_receivings r where r.id = rr_id
                  and public.pur_has_company(r.company_id) and public.pur_can_type(r.purchase_type)));
