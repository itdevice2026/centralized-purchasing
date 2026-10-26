-- Non-Trade supplier codes: VNT + 7 digits. Existing SUP-N-xxxxx suppliers renumbered VNT0000001.. in the same order.
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int; v_key text;
begin
  if new.code is null or btrim(new.code) = '' then
    if tg_table_name = 'pur_items' and new.purchase_type = 'Trade' then
      raise exception 'Item Code is required. Trade Item Codes are input by Accounting.';
    end if;
    if tg_table_name = 'pur_suppliers' then
      -- Trade: VT0200122, VT0200123 ... ; Non-Trade: VNT0000001 ...
      v_key := case when new.purchase_type = 'Trade' then 'VT' else 'VNT' end;
      insert into public.pur_counters(key, last_no) values (v_key, case when v_key = 'VT' then 200122 else 1 end)
      on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
      new.code := v_key || lpad(v_no::text, 7, '0');
    else
      v_prefix := 'ITM-' || public.pur_tcode(new.purchase_type);
      insert into public.pur_counters(key, last_no) values (v_prefix, 1)
      on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
      new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
    end if;
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;

with s as (select id, row_number() over (order by code) n from public.pur_suppliers where purchase_type = 'Non-Trade' and code like 'SUP-N-%')
update public.pur_suppliers p set code = 'VNT' || lpad(s.n::text, 7, '0') from s where p.id = s.id;

insert into public.pur_counters(key, last_no)
select 'VNT', coalesce(max(substr(code, 4)::int), 0) from public.pur_suppliers where code ~ '^VNT[0-9]{7}$'
on conflict (key) do update set last_no = excluded.last_no;
