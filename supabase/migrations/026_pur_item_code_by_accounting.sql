-- Item Codes are assigned manually by Accounting (no automatic item codes)
create or replace function public.pur_is_acct() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'accounting' from public.pur_profiles where user_id = auth.uid() and active), false)
$$;
revoke execute on function public.pur_is_acct() from public, anon;
grant execute on function public.pur_is_acct() to authenticated;

-- items: code is required; suppliers keep automatic codes
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int;
begin
  if tg_table_name = 'pur_items' then
    if new.code is null or btrim(new.code) = '' then
      raise exception 'Item Code is required. Item Codes are assigned by Accounting.';
    end if;
    new.code := upper(btrim(new.code));
    return new;
  end if;
  v_prefix := 'SUP-' || public.pur_tcode(new.purchase_type);
  if new.code is null or btrim(new.code) = '' then
    insert into public.pur_counters(key, last_no) values (v_prefix, 1)
    on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
    new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;

-- Accounting can see master data requests (to assign item codes)
drop policy if exists pur_mr_sel on public.pur_master_requests;
create policy pur_mr_sel on public.pur_master_requests for select to authenticated
  using (requested_by = (select auth.uid()) or (select public.pur_is_purch()) or (select public.pur_is_acct()));

-- Requests: only Accounting / Module Admin may put an item code on a request
create or replace function public.pur_master_request(p_kind text, p_action text, p_target uuid, p_payload jsonb, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_t text; v_p jsonb := coalesce(p_payload,'{}'::jsonb);
begin
  if coalesce(public.pur_role(),'viewer') = 'viewer' then raise exception 'You are not allowed to request master data changes.'; end if;
  if p_kind not in ('item','supplier') then raise exception 'Unknown master type.'; end if;
  if p_action <> 'create' and p_target is null then raise exception 'Select the record to change.'; end if;
  if p_kind = 'item' and not (public.pur_is_admin() or public.pur_is_acct()) then v_p := v_p - 'code'; end if;
  if p_action = 'create' then
    if p_kind = 'item' and coalesce(btrim(v_p->>'description'),'') = '' then raise exception 'Item description is required.'; end if;
    if p_kind = 'supplier' and coalesce(btrim(v_p->>'name'),'') = '' then raise exception 'Supplier name is required.'; end if;
    if coalesce(v_p->>'purchase_type','') not in ('Trade','Non-Trade') then raise exception 'Choose the module (Trade / Non-Trade).'; end if;
    perform public.pur_assert_type(v_p->>'purchase_type');
  else
    if p_kind = 'item' then select purchase_type into v_t from public.pur_items where id = p_target;
    else select purchase_type into v_t from public.pur_suppliers where id = p_target; end if;
    if v_t is null then raise exception 'Record not found.'; end if;
    perform public.pur_assert_type(v_t);
  end if;
  if p_target is not null and exists (select 1 from public.pur_master_requests where target_id = p_target and status = 'pending') then
    raise exception 'There is already a pending request for this record.'; end if;
  insert into public.pur_master_requests(req_no, kind, action, target_id, payload, reason, requested_by)
  values (public.pur_next_no(case when p_kind = 'item' then 'MRI' else 'MRS' end, null), p_kind, p_action, p_target,
          v_p - case when p_action <> 'create' then 'purchase_type' else '' end,
          coalesce(p_reason,''), auth.uid())
  returning id into v_id;
  perform public.pur_log('MR', v_id, null, 'requested ' || p_action || ' ' || p_kind, p_reason);
  return v_id;
end $$;

-- Accounting assigns the Item Code on a pending new-item request
create or replace function public.pur_mr_set_code(p_id uuid, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.pur_master_requests; v text := upper(btrim(coalesce(p_code,'')));
begin
  if not (public.pur_is_acct() or public.pur_is_admin()) then raise exception 'Only Accounting can assign Item Codes.'; end if;
  select * into m from public.pur_master_requests where id = p_id for update;
  if m.id is null or m.kind <> 'item' or m.action <> 'create' then raise exception 'Item Codes are assigned on new-item requests only.'; end if;
  if m.status <> 'pending' then raise exception 'Request is already %.', m.status; end if;
  if v = '' then raise exception 'Enter the Item Code.'; end if;
  if exists (select 1 from public.pur_items where code = v) then raise exception 'Item Code % is already used.', v; end if;
  if exists (select 1 from public.pur_master_requests where id <> p_id and status = 'pending' and kind = 'item' and upper(payload->>'code') = v) then
    raise exception 'Item Code % is already on another pending request.', v; end if;
  update public.pur_master_requests set payload = payload || jsonb_build_object('code', v) where id = p_id;
  perform public.pur_log('MR', p_id, null, 'item code assigned', v);
end $$;
revoke execute on function public.pur_mr_set_code(uuid, text) from public, anon;
grant execute on function public.pur_mr_set_code(uuid, text) to authenticated;

-- Accounting (or Module Admin) changes the Item Code of an existing item
create or replace function public.pur_item_set_code(p_item uuid, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare v text := upper(btrim(coalesce(p_code,''))); v_old text;
begin
  if not (public.pur_is_acct() or public.pur_is_admin()) then raise exception 'Only Accounting can assign Item Codes.'; end if;
  select code into v_old from public.pur_items where id = p_item;
  if v_old is null then raise exception 'Item not found.'; end if;
  if v = '' then raise exception 'Enter the Item Code.'; end if;
  if v = v_old then return; end if;
  if exists (select 1 from public.pur_items where code = v) then raise exception 'Item Code % is already used.', v; end if;
  update public.pur_items set code = v where id = p_item;
  perform public.pur_log('ITEM', p_item, null, 'item code changed', v_old || ' -> ' || v);
end $$;
revoke execute on function public.pur_item_set_code(uuid, text) from public, anon;
grant execute on function public.pur_item_set_code(uuid, text) to authenticated;

create or replace function public.pur_master_review(p_id uuid, p_decision text, p_remarks text default '') returns uuid
language plpgsql security definer set search_path = '' as $$
declare m public.pur_master_requests; v_res uuid; j jsonb;
begin
  if not public.pur_is_admin() then raise exception 'Only the Module Admin can approve master data changes.'; end if;
  select * into m from public.pur_master_requests where id = p_id for update;
  if m.status <> 'pending' then raise exception 'Request is already %.', m.status; end if;
  if p_decision = 'reject' then
    if coalesce(btrim(p_remarks),'') = '' then raise exception 'Please give a reason for rejecting.'; end if;
    update public.pur_master_requests set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_remarks = p_remarks where id = p_id;
    perform public.pur_log('MR', p_id, null, 'rejected', p_remarks);
    return null;
  elsif p_decision <> 'approve' then raise exception 'Decision must be approve or reject.';
  end if;
  j := m.payload;
  if m.kind = 'item' then
    if m.action = 'create' then
      if coalesce(btrim(j->>'code'),'') = '' then
        raise exception 'Waiting for Accounting to assign the Item Code before this item can be approved.';
      end if;
      insert into public.pur_items(code, description, purchase_type, uom, category, brand, specs, last_price)
      values (nullif(btrim(j->>'code'),''), btrim(j->>'description'), j->>'purchase_type', upper(coalesce(nullif(btrim(j->>'uom'),''),'PC')),
              coalesce(j->>'category',''), coalesce(j->>'brand',''), coalesce(j->>'specs',''), coalesce(nullif(j->>'last_price','')::numeric,0))
      returning id into v_res;
    elsif m.action = 'update' then
      update public.pur_items set
        description = coalesce(nullif(btrim(j->>'description'),''), description),
        uom = upper(coalesce(nullif(btrim(j->>'uom'),''), uom)),
        category = coalesce(j->>'category', category),
        brand = coalesce(j->>'brand', brand),
        specs = coalesce(j->>'specs', specs),
        last_price = coalesce(nullif(j->>'last_price','')::numeric, last_price)
      where id = m.target_id returning id into v_res;
    else
      update public.pur_items set status = case when m.action = 'activate' then 'active' else 'inactive' end
       where id = m.target_id returning id into v_res;
    end if;
  else
    if m.action = 'create' then
      insert into public.pur_suppliers(code, name, purchase_type, tin, address, contact_person, phone, email, payment_terms, vat_type, category)
      values (nullif(btrim(j->>'code'),''), btrim(j->>'name'), j->>'purchase_type', coalesce(j->>'tin',''), coalesce(j->>'address',''),
              coalesce(j->>'contact_person',''), coalesce(j->>'phone',''), coalesce(j->>'email',''),
              coalesce(j->>'payment_terms',''), coalesce(nullif(j->>'vat_type',''),'VAT'), coalesce(j->>'category',''))
      returning id into v_res;
    elsif m.action = 'update' then
      update public.pur_suppliers set
        name = coalesce(nullif(btrim(j->>'name'),''), name),
        tin = coalesce(j->>'tin', tin), address = coalesce(j->>'address', address),
        contact_person = coalesce(j->>'contact_person', contact_person), phone = coalesce(j->>'phone', phone),
        email = coalesce(j->>'email', email), payment_terms = coalesce(j->>'payment_terms', payment_terms),
        vat_type = coalesce(nullif(j->>'vat_type',''), vat_type), category = coalesce(j->>'category', category)
      where id = m.target_id returning id into v_res;
    else
      update public.pur_suppliers set status = case when m.action = 'activate' then 'active' else 'inactive' end
       where id = m.target_id returning id into v_res;
    end if;
  end if;
  if v_res is null then raise exception 'Target record not found.'; end if;
  update public.pur_master_requests set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
         review_remarks = coalesce(p_remarks,''), result_id = v_res where id = p_id;
  perform public.pur_log('MR', p_id, null, 'approved', p_remarks);
  return v_res;
end $$;

