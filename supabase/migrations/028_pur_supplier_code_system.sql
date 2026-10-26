-- Supplier codes: always system generated (still requested and approved). Trade ITEM codes: input by Accounting.
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int;
begin
  if new.code is null or btrim(new.code) = '' then
    if tg_table_name = 'pur_items' and new.purchase_type = 'Trade' then
      raise exception 'Item Code is required. Trade Item Codes are input by Accounting.';
    end if;
    v_prefix := case when tg_table_name = 'pur_items' then 'ITM-' else 'SUP-' end || public.pur_tcode(new.purchase_type);
    insert into public.pur_counters(key, last_no) values (v_prefix, 1)
    on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
    new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;

create or replace function public.pur_mr_set_code(p_id uuid, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.pur_master_requests; v text := upper(btrim(coalesce(p_code,'')));
begin
  select * into m from public.pur_master_requests where id = p_id for update;
  if m.id is null or m.kind <> 'item' or m.action <> 'create' then raise exception 'Codes are input on new-item requests only. Supplier codes are system generated.'; end if;
  if m.status <> 'pending' then raise exception 'Request is already %.', m.status; end if;
  if not (public.pur_is_admin() or (public.pur_is_acct() and m.payload->>'purchase_type' = 'Trade')) then
    raise exception 'Only Accounting can input Trade Item Codes.'; end if;
  if v = '' then raise exception 'Enter the Item Code.'; end if;
  if exists (select 1 from public.pur_items where code = v) then raise exception 'Item Code % is already used.', v; end if;
  if exists (select 1 from public.pur_master_requests where id <> p_id and status = 'pending' and kind = 'item' and upper(payload->>'code') = v) then
    raise exception 'Item Code % is already on another pending request.', v; end if;
  update public.pur_master_requests set payload = payload || jsonb_build_object('code', v) where id = p_id;
  perform public.pur_log('MR', p_id, null, 'item code input', v);
end $$;

create or replace function public.pur_master_set_code(p_kind text, p_id uuid, p_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare v text := upper(btrim(coalesce(p_code,''))); v_old text; v_t text;
begin
  if p_kind <> 'item' then raise exception 'Supplier codes are system generated.'; end if;
  select code, purchase_type into v_old, v_t from public.pur_items where id = p_id;
  if v_old is null then raise exception 'Item not found.'; end if;
  if not (public.pur_is_admin() or (public.pur_is_acct() and v_t = 'Trade')) then
    raise exception 'Only Accounting can input Trade Item Codes.'; end if;
  if v = '' then raise exception 'Enter the Item Code.'; end if;
  if v = v_old then return; end if;
  if exists (select 1 from public.pur_items where code = v) then raise exception 'Item Code % is already used.', v; end if;
  update public.pur_items set code = v where id = p_id;
  perform public.pur_log('ITEM', p_id, null, 'item code changed', v_old || ' -> ' || v);
end $$;

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
  if m.kind = 'item' and m.action = 'create' and j->>'purchase_type' = 'Trade' and coalesce(btrim(j->>'code'),'') = '' then
    raise exception 'Waiting for Accounting to input the Trade Item Code before this can be approved.';
  end if;
  if m.kind = 'supplier' then j := j - 'code'; end if;  -- supplier codes are always system generated
  if m.kind = 'item' then
    if m.action = 'create' then
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
      values (null, btrim(j->>'name'), j->>'purchase_type', coalesce(j->>'tin',''), coalesce(j->>'address',''),
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

