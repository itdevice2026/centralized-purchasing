# All Company Centralized Purchasing System

Single-page web app (GitHub Pages) + Supabase (`bom-system` project, tables prefixed `pur_`) for all Meatplus group companies:
MTC, PMAI, PAEI, FSEI, MLC, NBC.

## Modules: Trade and Non-Trade
Trade (goods for resale / production) and Non-Trade (supplies, services, assets) are **separate modules**, each with its own menu: Purchase Requisition, Canvass / RFQ, Purchase Orders, Receiving and its own **Supplier Master**.
- Separate numbering: `PR-T-MTC-2026-00001` / `PR-N-…`, `CV-T/N`, `PO-T/N`, `RR-T/N`; suppliers `SUP-T-00001` / `SUP-N-00001`.
- Each user has **Module access**: Trade only, Non-Trade only, or both — managed in **Module Admin → Module Users** (Trade team / Non-Trade team, one-click toggles). Users only see documents and suppliers of their modules; approvers still see what is routed to them.
- POs, canvasses and receiving reports inherit the module of their PR; a document's module never changes.
- Each supplier and item belongs to one module (it can't be moved); a canvass / PO only accepts active suppliers of the same module.
- Approval Matrix steps apply to **All**, **Trade** or **Non-Trade**.
- **Item Master** is also separate per module (`ITM-T-00001` / `ITM-N-00001`); PR and PO lines only accept items of the document's module.

## Workflow
1. **Purchase Requisition (PR)** — requester picks items from the Item Master, submits.
2. **Approval** — routed by the per-company **Approval Matrix** (PR and PO separately). A step applies when the amount is ≥ its minimum; steps run in order; several approvers on one step = any one may approve. Rejected documents go back to the preparer for editing and resubmission.
3. **Canvass / RFQ** — Purchasing enters supplier quotes per line, awards one supplier per line → one draft PO per winning supplier. (Or **Direct PO** from an approved PR.)
4. **Purchase Order** — adjust price/qty, VAT (exclusive / inclusive / non-VAT, 12%), submit for approval, print, mark as sent.
5. **Receiving** — receiver records deliveries against the PO (partial deliveries allowed). PO becomes *partial* / *received*; the PR closes when all its POs are received.

## Executive Dashboard (President)
Menu **Executive Dashboard** (role *President / Executive* or Module Admin). Read-only, all companies, both modules:
- Period (this month, last month, quarter, YTD, last 12 months, custom) and company filters; Excel export.
- Trade vs Non-Trade: purchase amount, paid, unpaid balance, payments made in the period, awaiting approval, open for delivery.
- Monthly purchases (12 months) and purchases by company, Trade vs Non-Trade.
- Purchases list with **amount, PO status, payment status, amount paid, balance and date of payment**.
- Documents waiting for approval (days waiting, who it is waiting on) and top suppliers.

## Payments
Accounting / Purchasing record payments on approved POs (date of payment, amount, mode, check/OR/transfer reference). POs show **Unpaid / Partially paid / Paid**, amount paid, balance and last payment date. Overpayment is blocked; Accounting / Module Admin can void a payment with a reason.

## Master data control
Item Master and Supplier Master are controlled by the **Module Admin**. Other users submit *Master Data Requests* (new / change / deactivate / activate). The Module Admin approves or rejects; approved requests are applied automatically. Only active (approved) items and suppliers can be used on PRs, canvasses and POs.

## Roles
| Role | Can do |
|---|---|
| Module Admin | Everything + Setup (approval matrix, users, companies, departments), edits/approves master data |
| Purchasing | All companies; canvass, POs, receiving, PRs |
| Requester | PRs for assigned companies |
| Receiver | Receiving for assigned companies |
| Viewer | Read only for assigned companies |
| President / Executive | Executive Dashboard; read-only view of all companies and both modules |
| Accounting | All companies; records and voids payments on POs |

Anyone listed in the Approval Matrix can approve, whatever their role.

## Document numbers
`PR-T-MTC-2026-00001` (Trade) / `PR-N-MTC-2026-00001` (Non-Trade), same for CV, PO, RR — per module, company and year; items `ITM-T-00001` / `ITM-N-00001`; suppliers `SUP-T-00001` / `SUP-N-00001`.

## Backend
- `supabase/migrations/*.sql` — schema, RLS, workflow functions (already applied to `bom-system`).
- `supabase/functions/pur-admin` — Module Admin user creation / password reset (deployed).
- Status changes only happen through the `pur_*` security-definer RPCs; direct edits are locked once a document leaves draft.
- Logins are shared with the other Meatplus apps (same Supabase Auth).

## Deploy
GitHub → Settings → Pages → Deploy from branch `main` / root. Optional custom domain via `CNAME`.
