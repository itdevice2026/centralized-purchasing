# All Company Centralized Purchasing System

Single-page web app (GitHub Pages) + Supabase (`bom-system` project, tables prefixed `pur_`) for all Meatplus group companies:
MTC, PMAI, PAEI, FSEI, MLC, NBC.

## Workflow
1. **Purchase Requisition (PR)** — requester picks items from the Item Master, submits.
2. **Approval** — routed by the per-company **Approval Matrix** (PR and PO separately). A step applies when the amount is ≥ its minimum; steps run in order; several approvers on one step = any one may approve. Rejected documents go back to the preparer for editing and resubmission.
3. **Canvass / RFQ** — Purchasing enters supplier quotes per line, awards one supplier per line → one draft PO per winning supplier. (Or **Direct PO** from an approved PR.)
4. **Purchase Order** — adjust price/qty, VAT (exclusive / inclusive / non-VAT, 12%), submit for approval, print, mark as sent.
5. **Receiving** — receiver records deliveries against the PO (partial deliveries allowed). PO becomes *partial* / *received*; the PR closes when all its POs are received.

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

Anyone listed in the Approval Matrix can approve, whatever their role.

## Document numbers
`PR-MTC-2026-00001`, `CV-…`, `PO-…`, `RR-…` per company per year; items `ITM-00001`, suppliers `SUP-00001`.

## Backend
- `supabase/migrations/*.sql` — schema, RLS, workflow functions (already applied to `bom-system`).
- `supabase/functions/pur-admin` — Module Admin user creation / password reset (deployed).
- Status changes only happen through the `pur_*` security-definer RPCs; direct edits are locked once a document leaves draft.
- Logins are shared with the other Meatplus apps (same Supabase Auth).

## Deploy
GitHub → Settings → Pages → Deploy from branch `main` / root. Optional custom domain via `CNAME`.
