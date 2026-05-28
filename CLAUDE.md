# UBBS — Usage-Based Billing System

## What this is
Streamlit + Supabase venue billing app. Single venue in Manila.
Tracks customer time, charges ₱100/hr or ₱250/5hr with a 15-min grace
period and auto-extensions after grace.

## Tech stack
- Frontend: Streamlit (single-file `app.py`, NO `pages/` directory — sidebar
  is intentionally hidden via CSS injection)
- Backend: Supabase (Postgres + Edge Functions + Auth)
- Email: Resend via the `send-receipt` Edge Function
- Session persistence: streamlit-cookies-controller
- Realtime sync: st.fragment(run_every=2), polling-based

## Money convention
All money is stored as BIGINT centavos in the DB. Never NUMERIC pesos.
₱100.00 = 10000 centavos. Convert at the UI boundary only.

## Schema invariants
- One OPEN shift at a time (partial unique index enforces).
- `shifts.opening_cash_centavos = NULL` means "needs entry" (admin voided it,
  or never recorded). The shift_gate UI blocks dashboard access until it's set.
- `transactions` has `start_time`, `end_time`, `contracted_end` is COMPUTED as
  `end_time - (auto_extension_count * auto_extension_minutes)`.
- Grace period = 15 minutes past contracted_end with no charge.
- After grace, +1 auto-extension applied per hour (1 line item per hour).
- Extension cutover rule: `now < contracted_end` → extend same tx;
  `now >= contracted_end` → close old tx, open new tx (two transactions).

## Roles
- staff: open shifts, close orders, register cash movements
- manager: all of staff + void transactions
- admin: all of manager + analytics, alerts, cash overrides, create users

## Known landmines
- `LANGUAGE sql` functions with `RETURNS TABLE` MUST use table aliases for
  all column refs. Bare column names hit a Postgres parser bug. Example:
  `FROM transactions t WHERE t.status = ...` not `FROM transactions WHERE status = ...`
- Resend will silently bounce emails if the sending domain isn't verified at
  resend.com/domains. Check there first when receipts don't arrive.
- pg_net and pg_cron extensions must be enabled in Supabase before migration.

## How to run
- Migrations: paste `0001_ubbs_v2.sql` into Supabase SQL Editor, watch the
  Notices panel for "ALL N SMOKE TESTS PASSED".
- Edge Functions: `supabase functions deploy send-receipt --no-verify-jwt`
- App: `streamlit run app.py --server.port 8501`

## V2 status
The consolidated 0001_ubbs_v2.sql migration was built but has not yet been
applied. Schema is from a clean slate (DROP SCHEMA public CASCADE).
First admin user is bootstrapped manually via Supabase dashboard.