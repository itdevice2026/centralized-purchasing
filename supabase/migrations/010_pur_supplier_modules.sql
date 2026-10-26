-- Separate Supplier Masters for Trade and Non-Trade
-- * supplier codes per module: SUP-T-00001 / SUP-N-00001 (items keep ITM-00001)
-- * a supplier's module cannot change
-- * users only see suppliers of modules they can access
-- * supplier master requests carry the module; pur_master_review creates suppliers in that module
--   (full function bodies as applied: see pur_master_request / pur_master_review in the database)
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int;
begin
  v_prefix := case when tg_table_name = 'pur_items' then 'ITM' else 'SUP-' || public.pur_tcode(new.purchase_type) end;
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
    raise exception 'A supplier''s module (Trade / Non-Trade) cannot be changed. Add it as a new supplier in the other module.';
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_sup_lock() from public, anon, authenticated;
drop trigger if exists pur_sup_lock on public.pur_suppliers;
create trigger pur_sup_lock before update on public.pur_suppliers for each row execute function public.pur_tg_sup_lock();

drop policy if exists pur_suppliers_sel on public.pur_suppliers;
create policy pur_suppliers_sel on public.pur_suppliers for select to authenticated
  using ((select public.pur_role()) is not null and public.pur_can_type(purchase_type));
