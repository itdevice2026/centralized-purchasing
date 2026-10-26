-- Trade supplier codes: VT + 7 digits, starting at VT0200122 (Non-Trade stays SUP-N-00000)
create or replace function public.pur_tg_master_code() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_prefix text; v_no int;
begin
  if new.code is null or btrim(new.code) = '' then
    if tg_table_name = 'pur_items' and new.purchase_type = 'Trade' then
      raise exception 'Item Code is required. Trade Item Codes are input by Accounting.';
    end if;
    if tg_table_name = 'pur_suppliers' and new.purchase_type = 'Trade' then
      insert into public.pur_counters(key, last_no) values ('VT', 200122)
      on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
      new.code := 'VT' || lpad(v_no::text, 7, '0');
    else
      v_prefix := case when tg_table_name = 'pur_items' then 'ITM-' else 'SUP-' end || public.pur_tcode(new.purchase_type);
      insert into public.pur_counters(key, last_no) values (v_prefix, 1)
      on conflict (key) do update set last_no = public.pur_counters.last_no + 1 returning last_no into v_no;
      new.code := v_prefix || '-' || lpad(v_no::text, 5, '0');
    end if;
  end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;
delete from public.pur_counters where key = 'VT';
