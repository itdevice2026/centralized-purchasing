-- Purchase Type: Trade / Non-Trade
alter table public.pur_requisitions add column if not exists purchase_type text not null default 'Non-Trade' check (purchase_type in ('Trade','Non-Trade'));
alter table public.pur_purchase_orders add column if not exists purchase_type text not null default 'Non-Trade' check (purchase_type in ('Trade','Non-Trade'));
alter table public.pur_items add column if not exists purchase_type text not null default 'Both' check (purchase_type in ('Both','Trade','Non-Trade'));
alter table public.pur_approval_rules add column if not exists purchase_type text not null default 'All' check (purchase_type in ('All','Trade','Non-Trade'));
alter table public.pur_approval_rules drop constraint if exists pur_approval_rules_company_id_doc_type_step_no_approver_id_key;
alter table public.pur_approval_rules add constraint pur_approval_rules_uniq unique (company_id, doc_type, purchase_type, step_no, approver_id);
create index if not exists pur_req_type_idx on public.pur_requisitions(purchase_type);
create index if not exists pur_po_type_idx on public.pur_purchase_orders(purchase_type);

-- A PO created from a PR always carries the PR's purchase type
create or replace function public.pur_tg_po_type() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.pr_id is not null then
    select purchase_type into new.purchase_type from public.pur_requisitions where id = new.pr_id;
  end if;
  return new;
end $$;
revoke all on function public.pur_tg_po_type() from public, anon, authenticated;
drop trigger if exists pur_po_type on public.pur_purchase_orders;
create trigger pur_po_type before insert or update of purchase_type, pr_id on public.pur_purchase_orders
  for each row execute function public.pur_tg_po_type();

-- pur_submit and pur_master_review are replaced in this migration (see the applied versions in the database):
--  * pur_submit filters approval rules by purchase_type in ('All', <doc type>) and blocks PR lines whose item
--    purchase_type is not 'Both' or the PR's type.
--  * pur_master_review reads/writes pur_items.purchase_type.
