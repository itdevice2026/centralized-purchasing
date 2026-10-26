-- Separate Item Masters for Trade and Non-Trade
-- * items belong to exactly one module (no more 'Both'); codes ITM-T-00001 / ITM-N-00001
-- * module can't change; users see only items of their modules
-- * item master requests carry the module
alter table public.pur_items drop constraint if exists pur_items_purchase_type_check;
update public.pur_items set purchase_type = 'Non-Trade' where purchase_type = 'Both';
alter table public.pur_items alter column purchase_type set default 'Non-Trade';
alter table public.pur_items add constraint pur_items_purchase_type_check check (purchase_type in ('Trade','Non-Trade'));
create index if not exists pur_items_type_idx on public.pur_items(purchase_type);

create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int;
begin
  v_prefix := case when tg_table_name = 'pur_items' then 'ITM-' else 'SUP-' end || public.pur_tcode(new.purchase_type);
  if new.code is null or btrim(new.code) = '' then
    insert into public.pur_counters(key, last_no) values (v_prefix, 1)
    on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
    new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;
revoke all on function public.pur_tg_master_code() from public, anon, authenticated;

create or replace function public.pur_tg_sup_lock() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.purchase_type is distinct from old.purchase_type then
    raise exception 'The module (Trade / Non-Trade) of a master record cannot be changed. Add it as a new record in the other module.';
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_sup_lock() from public, anon, authenticated;
drop trigger if exists pur_item_lock on public.pur_items;
create trigger pur_item_lock before update on public.pur_items for each row execute function public.pur_tg_sup_lock();

drop policy if exists pur_items_sel on public.pur_items;
create policy pur_items_sel on public.pur_items for select to authenticated
  using ((select public.pur_role()) is not null and public.pur_can_type(purchase_type));

create or replace function public.pur_master_request(p_kind text, p_action text, p_target uuid, p_payload jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_t text;
begin
  if coalesce(public.pur_role(),'viewer') = 'viewer' then raise exception 'You are not allowed to request master data changes.'; end if;
  if p_kind not in ('item','supplier') then raise exception 'Unknown master type.'; end if;
  if p_action <> 'create' and p_target is null then raise exception 'Select the record to change.'; end if;
  if p_action = 'create' then
    if p_kind = 'item' and coalesce(btrim(p_payload->>'description'),'') = '' then raise exception 'Item description is required.'; end if;
    if p_kind = 'supplier' and coalesce(btrim(p_payload->>'name'),'') = '' then raise exception 'Supplier name is required.'; end if;
    if coalesce(p_payload->>'purchase_type','') not in ('Trade','Non-Trade') then raise exception 'Choose the module (Trade / Non-Trade).'; end if;
    perform public.pur_assert_type(p_payload->>'purchase_type');
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
          coalesce(p_payload,'{}'::jsonb) - case when p_action <> 'create' then 'purchase_type' else '' end,
          coalesce(p_reason,''), auth.uid())
  returning id into v_id;
  perform public.pur_log('MR', v_id, null, 'requested ' || p_action || ' ' || p_kind, p_reason);
  return v_id;
end $$;

create or replace function public.pur_master_review(p_id uuid, p_decision text, p_remarks text default '')
returns uuid language plpgsql security definer set search_path = '' as $$
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
      insert into public.pur_items(code, description, purchase_type, uom, category, specs, last_price)
      values (nullif(btrim(j->>'code'),''), btrim(j->>'description'), j->>'purchase_type', upper(coalesce(nullif(btrim(j->>'uom'),''),'PC')),
              coalesce(j->>'category',''), coalesce(j->>'specs',''), coalesce(nullif(j->>'last_price','')::numeric,0))
      returning id into v_res;
    elsif m.action = 'update' then
      update public.pur_items set
        description = coalesce(nullif(btrim(j->>'description'),''), description),
        uom = upper(coalesce(nullif(btrim(j->>'uom'),''), uom)),
        category = coalesce(j->>'category', category),
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

-- PR / PO lines may only use items of the document's module
create or replace function public.pur_tg_line_item_type() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_doc text; v_item text;
begin
  if new.item_id is null then return new; end if;
  if tg_table_name = 'pur_pr_lines' then select purchase_type into v_doc from public.pur_requisitions where id = new.pr_id;
  else select purchase_type into v_doc from public.pur_purchase_orders where id = new.po_id; end if;
  select purchase_type into v_item from public.pur_items where id = new.item_id;
  if v_item is distinct from v_doc then
    raise exception 'Item "%" belongs to the % Item Master and cannot be used on a % document.', new.description, v_item, v_doc;
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_line_item_type() from public, anon, authenticated;
drop trigger if exists pur_prl_item_type on public.pur_pr_lines;
create trigger pur_prl_item_type before insert or update of item_id on public.pur_pr_lines for each row execute function public.pur_tg_line_item_type();
drop trigger if exists pur_pol_item_type on public.pur_po_lines;
create trigger pur_pol_item_type before insert or update of item_id on public.pur_po_lines for each row execute function public.pur_tg_line_item_type();
