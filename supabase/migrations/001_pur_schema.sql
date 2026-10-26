-- =====================================================================
-- ALL COMPANY CENTRALIZED PURCHASING SYSTEM  (table prefix: pur_)
-- PR -> Approval -> Canvass/RFQ -> PO -> Approval -> Receiving
-- Item & Supplier master changes are controlled by the Module Admin
-- through an approval queue (pur_master_requests).
-- =====================================================================

-- ---------- Core / setup ----------
create table if not exists public.pur_companies (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  address text default '',
  tin text default '',
  logo text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.pur_departments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.pur_companies(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  unique (company_id, name)
);

create table if not exists public.pur_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  position text default '',
  role text not null default 'requester'
    check (role in ('admin','purchasing','requester','receiver','viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.pur_user_companies (
  user_id uuid not null references public.pur_profiles(user_id) on delete cascade,
  company_id uuid not null references public.pur_companies(id) on delete cascade,
  primary key (user_id, company_id)
);

-- Approval matrix: per company, per document, by amount.
-- A step applies when document total >= min_amount.
-- Several approvers on the same step = any one of them may approve.
create table if not exists public.pur_approval_rules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.pur_companies(id) on delete cascade,
  doc_type text not null check (doc_type in ('PR','PO')),
  step_no int not null check (step_no between 1 and 9),
  step_name text not null default '',
  approver_id uuid not null references public.pur_profiles(user_id) on delete cascade,
  min_amount numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  unique (company_id, doc_type, step_no, approver_id)
);

create table if not exists public.pur_counters (
  key text primary key,
  last_no int not null default 0
);
comment on table public.pur_counters is 'Document-number counters; written only by pur_next_no (security definer). No client policies by design.';

-- ---------- Master data (shared by all companies) ----------
create table if not exists public.pur_suppliers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  tin text default '',
  address text default '',
  contact_person text default '',
  phone text default '',
  email text default '',
  payment_terms text default '',
  vat_type text not null default 'VAT' check (vat_type in ('VAT','NON-VAT')),
  category text default '',
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pur_items (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text not null,
  uom text not null default 'PC',
  category text default '',
  specs text default '',
  last_price numeric(14,4) default 0,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pur_master_requests (
  id uuid primary key default gen_random_uuid(),
  req_no text not null unique,
  kind text not null check (kind in ('item','supplier')),
  action text not null check (action in ('create','update','deactivate','activate')),
  target_id uuid,
  payload jsonb not null default '{}'::jsonb,
  reason text default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_by uuid not null references public.pur_profiles(user_id),
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.pur_profiles(user_id),
  reviewed_at timestamptz,
  review_remarks text default '',
  result_id uuid
);

-- ---------- Purchase Requisition ----------
create table if not exists public.pur_requisitions (
  id uuid primary key default gen_random_uuid(),
  pr_no text unique,
  company_id uuid not null references public.pur_companies(id),
  department_id uuid references public.pur_departments(id),
  requested_by uuid not null references public.pur_profiles(user_id),
  request_date date not null default current_date,
  date_needed date,
  purpose text default '',
  priority text not null default 'Normal' check (priority in ('Normal','Urgent','Critical')),
  status text not null default 'draft'
    check (status in ('draft','pending','approved','rejected','canvassing','ordered','closed','cancelled')),
  total numeric(14,2) not null default 0,
  submitted_at timestamptz,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pur_pr_lines (
  id uuid primary key default gen_random_uuid(),
  pr_id uuid not null references public.pur_requisitions(id) on delete cascade,
  line_no int not null default 1,
  item_id uuid references public.pur_items(id),
  description text not null,
  uom text not null default 'PC',
  qty numeric(14,3) not null check (qty > 0),
  est_unit_cost numeric(14,4) not null default 0 check (est_unit_cost >= 0),
  amount numeric(14,2) generated always as (round(qty * est_unit_cost, 2)) stored,
  remarks text default ''
);

-- ---------- Approvals (PR and PO) ----------
create table if not exists public.pur_approvals (
  id uuid primary key default gen_random_uuid(),
  doc_type text not null check (doc_type in ('PR','PO')),
  doc_id uuid not null,
  company_id uuid not null references public.pur_companies(id),
  round int not null default 1,
  step_no int not null,
  step_name text default '',
  approver_id uuid not null references public.pur_profiles(user_id),
  status text not null default 'pending' check (status in ('pending','approved','rejected','skipped')),
  remarks text default '',
  acted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists pur_approvals_doc_idx on public.pur_approvals(doc_type, doc_id);
create index if not exists pur_approvals_me_idx on public.pur_approvals(approver_id, status);

-- ---------- Canvass / RFQ ----------
create table if not exists public.pur_canvasses (
  id uuid primary key default gen_random_uuid(),
  cv_no text unique,
  pr_id uuid not null references public.pur_requisitions(id),
  company_id uuid not null references public.pur_companies(id),
  status text not null default 'draft' check (status in ('draft','awarded','cancelled')),
  notes text default '',
  created_by uuid not null references public.pur_profiles(user_id),
  created_at timestamptz not null default now(),
  awarded_at timestamptz
);

create table if not exists public.pur_canvass_suppliers (
  id uuid primary key default gen_random_uuid(),
  canvass_id uuid not null references public.pur_canvasses(id) on delete cascade,
  supplier_id uuid not null references public.pur_suppliers(id),
  quote_ref text default '',
  payment_terms text default '',
  lead_time text default '',
  remarks text default '',
  unique (canvass_id, supplier_id)
);

create table if not exists public.pur_canvass_prices (
  id uuid primary key default gen_random_uuid(),
  canvass_id uuid not null references public.pur_canvasses(id) on delete cascade,
  cs_id uuid not null references public.pur_canvass_suppliers(id) on delete cascade,
  pr_line_id uuid not null references public.pur_pr_lines(id) on delete cascade,
  unit_price numeric(14,4) not null check (unit_price >= 0),
  awarded boolean not null default false,
  unique (cs_id, pr_line_id)
);

-- ---------- Purchase Order ----------
create table if not exists public.pur_purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_no text unique,
  company_id uuid not null references public.pur_companies(id),
  supplier_id uuid not null references public.pur_suppliers(id),
  pr_id uuid references public.pur_requisitions(id),
  canvass_id uuid references public.pur_canvasses(id),
  po_date date not null default current_date,
  delivery_date date,
  delivery_address text default '',
  payment_terms text default '',
  vat_type text not null default 'VAT-EXCLUSIVE' check (vat_type in ('VAT-EXCLUSIVE','VAT-INCLUSIVE','NON-VAT')),
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  remarks text default '',
  status text not null default 'draft'
    check (status in ('draft','pending','approved','rejected','sent','partial','received','closed','cancelled')),
  created_by uuid not null references public.pur_profiles(user_id),
  submitted_at timestamptz,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pur_po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.pur_purchase_orders(id) on delete cascade,
  line_no int not null default 1,
  pr_line_id uuid references public.pur_pr_lines(id),
  item_id uuid references public.pur_items(id),
  description text not null,
  uom text not null default 'PC',
  qty numeric(14,3) not null check (qty > 0),
  unit_price numeric(14,4) not null default 0 check (unit_price >= 0),
  amount numeric(14,2) generated always as (round(qty * unit_price, 2)) stored,
  qty_received numeric(14,3) not null default 0
);

-- ---------- Receiving ----------
create table if not exists public.pur_receivings (
  id uuid primary key default gen_random_uuid(),
  rr_no text unique,
  po_id uuid not null references public.pur_purchase_orders(id),
  company_id uuid not null references public.pur_companies(id),
  received_by uuid not null references public.pur_profiles(user_id),
  received_date date not null default current_date,
  dr_no text default '',
  invoice_no text default '',
  remarks text default '',
  created_at timestamptz not null default now()
);

create table if not exists public.pur_rr_lines (
  id uuid primary key default gen_random_uuid(),
  rr_id uuid not null references public.pur_receivings(id) on delete cascade,
  po_line_id uuid not null references public.pur_po_lines(id),
  qty_received numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_rejected numeric(14,3) not null default 0 check (qty_rejected >= 0),
  remarks text default ''
);

create table if not exists public.pur_activity (
  id bigserial primary key,
  doc_type text not null,
  doc_id uuid,
  company_id uuid,
  action text not null,
  details text default '',
  actor uuid default auth.uid(),
  at timestamptz not null default now()
);
create index if not exists pur_activity_doc_idx on public.pur_activity(doc_type, doc_id);

-- FK indexes
create index if not exists pur_pr_lines_pr_idx on public.pur_pr_lines(pr_id);
create index if not exists pur_po_lines_po_idx on public.pur_po_lines(po_id);
create index if not exists pur_rr_lines_rr_idx on public.pur_rr_lines(rr_id);
create index if not exists pur_cp_cv_idx on public.pur_canvass_prices(canvass_id);
create index if not exists pur_cs_cv_idx on public.pur_canvass_suppliers(canvass_id);
create index if not exists pur_req_company_idx on public.pur_requisitions(company_id, status);
create index if not exists pur_po_company_idx on public.pur_purchase_orders(company_id, status);
create index if not exists pur_po_pr_idx on public.pur_purchase_orders(pr_id);
create index if not exists pur_rr_po_idx on public.pur_receivings(po_id);
create index if not exists pur_cv_pr_idx on public.pur_canvasses(pr_id);
