-- PR form fields matching the company's Purchase Requisition layout
alter table public.pur_requisitions add column if not exists delivery_address text not null default '';
alter table public.pur_requisitions add column if not exists other_remarks text not null default '';
alter table public.pur_pr_lines add column if not exists cost_center text not null default '';

-- POs created from a PR use the PR's delivery address when one is given
create or replace function public.pur_tg_po_deliv() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  if new.pr_id is not null then
    select delivery_address into v from public.pur_requisitions where id = new.pr_id;
    if coalesce(btrim(v),'') <> '' then new.delivery_address := v; end if;
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_po_deliv() from public, anon, authenticated;
drop trigger if exists pur_po_deliv on public.pur_purchase_orders;
create trigger pur_po_deliv before insert on public.pur_purchase_orders for each row execute function public.pur_tg_po_deliv();
