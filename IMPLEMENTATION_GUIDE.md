# UBBS V2 — Implementation Guide (Path 1: Clean Slate)

This guide takes you from your current Supabase project state to a fully working
UBBS V2 deployment. You chose **Path 1**, meaning your existing `public` schema
gets dropped entirely and rebuilt from one consolidated migration.

Total time: ~30 minutes if nothing goes wrong.

---

## Pre-flight: confirm nothing's worth keeping

You said earlier: "There is nothing important in the data anyway." Just so it's
in writing — running this guide will **permanently delete**:

- All rows in `transactions`, `customer_profiles`, `daily_cash_logs`, `time_logs`, `profiles`, `refunds`, `shifts`, `admin_alerts`, `audit_log`, `staff_profiles`
- All custom functions and triggers
- All custom enums and types
- Any other tables in the `public` schema I don't know about

**What survives:** users in `auth.users` (different schema), Supabase project
settings, your API keys, deployed Edge Functions.

If anything in the above list might be valuable, stop here and copy it out
first. Otherwise, proceed.

---

## Step 1 — Wipe the public schema

### 1.1 Open the Supabase SQL Editor
Dashboard → your project → **SQL Editor** → **New query**.

### 1.2 Run the wipe
Paste this and click **Run**:

```sql
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;
```

Expected output: `Success. No rows returned.`

### 1.3 Verify it's empty
```sql
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';
```

Expected output: **zero rows**. If you see any tables, the drop didn't work
fully — paste the output back to me before continuing.

---

## Step 2 — Run the consolidated V2 migration

### 2.1 Open `0001_ubbs_v2.sql`
This is the main file in the package. It's ~1,700 lines and builds everything:
tables, enums, functions, triggers, RLS policies, the PII purge cron, and
finishes with a smoke test that exercises every read-only function.

### 2.2 Paste and run
Copy the entire file into the SQL Editor. Click **Run**.

### 2.3 Check the Notices panel — this is the important part
The result pane will say "Success. No rows returned." That alone is **not**
enough confirmation. You must scroll to the **Messages / Notices** section
below the results pane. You should see one of these blocks:

**On success:**
```
NOTICE:  ----------------------------------------------------------
NOTICE:  UBBS V2 MIGRATION: ALL 21 SMOKE TESTS PASSED
NOTICE:  ----------------------------------------------------------
NOTICE:  Next steps:
NOTICE:    1. Set app.functions_base_url + app.cron_secret
NOTICE:    2. Deploy the send-receipt Edge Function
NOTICE:    3. Create your first admin auth user + staff_profiles row
NOTICE:    4. Run: streamlit run app.py
```

**On failure:**
```
WARNING:  UBBS V2 MIGRATION: 18 PASSED, 3 FAILED
WARNING:  Failures:
WARNING:    analytics_revenue_rollup: column "..." does not exist
...
```

If you see `WARNING` lines, copy them and paste back to me. The smoke test
tells me exactly which function broke and why — much better than chasing
errors at app runtime.

---

## Step 3 — Configure the receipt email pipeline

The DB trigger that fires after each checkout needs to know where to call
the Edge Function and what secret to authenticate with.

### 3.1 Find your project ref
Your Supabase URL looks like `https://abcdefgh.supabase.co`. The `abcdefgh`
part is your project ref.

### 3.2 Generate a random secret
Run this in your terminal (or use any password generator):
```bash
openssl rand -hex 32
```
Copy the output. You'll paste it in two places.

### 3.3 Set Postgres settings
Back in the SQL Editor:
```sql
ALTER DATABASE postgres
  SET app.functions_base_url = 'https://YOUR_PROJECT_REF.supabase.co/functions/v1';

ALTER DATABASE postgres
  SET app.cron_secret = 'PASTE-YOUR-RANDOM-SECRET-HERE';
```

Verify:
```sql
SHOW app.functions_base_url;
SHOW app.cron_secret;
```

Both should return the values you just set.

---

## Step 4 — Deploy the receipt Edge Function

### 4.1 Install the Supabase CLI (if you haven't)

macOS: `brew install supabase/tap/supabase`
Windows (Scoop): `scoop install supabase`
Linux/other: <https://github.com/supabase/cli#install-the-cli>

### 4.2 Link your project
```bash
cd /path/to/the/extracted/ubbs-v2/
supabase login    # opens browser to get an access token
supabase link --project-ref YOUR_PROJECT_REF
```

### 4.3 Set Edge Function secrets
```bash
supabase secrets set CRON_SECRET='PASTE-SAME-SECRET-FROM-STEP-3.2'
supabase secrets set RESEND_API_KEY='re_your_actual_resend_key'
supabase secrets set RESEND_FROM_ADDRESS='UBBS Receipts <receipts@yourdomain.com>'
```

> **Critical for receipts to actually deliver:**
> `RESEND_FROM_ADDRESS` must use a domain that's **verified** in your Resend
> dashboard at <https://resend.com/domains>. Unverified domains silently
> fail to send. This was almost certainly the reason your V1 emails never
> arrived. For initial testing you can use Resend's built-in sandbox sender
> `onboarding@resend.dev` — it only delivers to the email that owns the
> Resend account, but it confirms the wiring works before you point at
> your real domain.

### 4.4 Deploy the function
```bash
supabase functions deploy send-receipt --no-verify-jwt
```

The `--no-verify-jwt` flag is essential — the function uses its own
`CRON_SECRET` for auth, not Supabase JWTs.

### 4.5 (Optional) Smoke-test the function
```bash
supabase functions logs send-receipt --tail
```

Leave that running, then in a new terminal do a fake invocation:
```bash
curl -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-receipt" \
  -H "Authorization: Bearer YOUR_CRON_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"transaction_id": "00000000-0000-0000-0000-000000000000"}'
```

You should see in the logs: `send_receipt_failed ... transaction not found`.
That's the expected "happy" failure — it means the auth and the DB lookup
both worked; it just couldn't find a real transaction. Good signal that
the pipeline is wired correctly.

---

## Step 5 — Create your first admin user (bootstrap)

The app has an in-app "Create User" screen, but you need an admin to use it.
Bootstrap the first admin manually.

### 5.1 Create the auth user
Dashboard → **Authentication** → **Users** → **Add user** → **Create new user**:
- Email: your admin email
- Password: any password ≥6 chars (you can change later)
- Check **Auto Confirm User**
- Click **Create user**

### 5.2 Copy the new user's UUID
After creation, the user appears in the list. Click them and copy the UUID
shown at the top of their profile.

### 5.3 Insert the matching staff profile
Back in the SQL Editor:
```sql
INSERT INTO staff_profiles (user_id, display_name, role)
VALUES ('PASTE-UUID-HERE', 'Your Name', 'admin');
```

Verify:
```sql
SELECT user_id, display_name, role FROM staff_profiles;
```

Should show one row.

---

## Step 6 — Run the Streamlit app locally in VS Code

### 6.1 Open the project folder in VS Code
File → Open Folder → select the extracted `ubbs-v2/` directory.

### 6.2 Set up Python environment
In the VS Code integrated terminal (Ctrl+\` or Cmd+\`):
```bash
python3 -m venv .venv
source .venv/bin/activate         # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 6.3 Configure Streamlit secrets
Create the folder `.streamlit/` in the project root if it doesn't exist,
then create `.streamlit/secrets.toml` with:

```toml
SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co"
SUPABASE_ANON_KEY = "eyJ...your-anon-key..."
SUPABASE_SERVICE_ROLE_KEY = "eyJ...your-service-role-key..."
```

Find all three values at:
Dashboard → **Project Settings** → **API**.

> **Never commit this file to git.** Service role keys bypass Row-Level
> Security. The app uses it only inside the admin "Create User" screen.

### 6.4 Launch
```bash
streamlit run app.py --server.port 8501
```

VS Code will prompt you to open `http://localhost:8501`. Click through.

---

## Step 7 — First-run verification

Walk through this checklist in order. Don't skip any step — each one
catches a different class of bug.

### 7.1 No sidebar
The app should load with no left-hand navigation. If you see a sidebar
listing "app", "admin funnel", "cx funnel", etc., the `hide_streamlit_chrome`
CSS injection didn't load. Hard-refresh with Ctrl+Shift+R.

### 7.2 Login + session persistence
- Sign in with the admin email/password from Step 5.
- Refresh the browser (F5). **You should stay signed in.** If you get
  bounced to the login page, the cookie persistence is broken — most
  likely the `streamlit-cookies-controller` package didn't install. Check
  `pip list | grep cookies`.

### 7.3 Mandatory cash gate
First post-login screen asks for opening cash. Enter something like 5000
and click record. Dashboard appears.

### 7.4 Customer registration (public route)
Open a new tab: `http://localhost:8501/?page=register`. The customer
registration form loads with no auth required. Fill it out:
- First Name + Last Name
- Email
- Occupation: pick "Student" → school field appears
- Fill school, submit

You should see a green success message.

### 7.5 POS lookup
Back on the admin dashboard → Staff Features → New Order. Enter the email
you just registered. Click Look Up. The customer's name appears.

### 7.6 Cash change calculator
- Pick "5 Hours — ₱250.00"
- Pick "CASH"
- Enter ₱500 tendered

Change displays as ₱250.00 instantly. Click "Confirm Order & Start Timer".

### 7.7 Active session table
The Active Sessions tab shows the customer with a 5-hour countdown,
no color (within scheduled time).

### 7.8 Trigger the color states without waiting 5 hours
Use the SQL Editor to fast-forward the session:
```sql
-- Move the end time to 10 minutes ago → yellow (grace).
UPDATE transactions SET end_time = NOW() - INTERVAL '10 minutes'
WHERE status = 'ACTIVE';
```
Refresh the app. The row should turn **yellow** with "GRACE — 5 min left".

```sql
-- Move it to 30 minutes ago → red (past grace, +1 auto-extension applied).
UPDATE transactions SET end_time = NOW() - INTERVAL '30 minutes'
WHERE status = 'ACTIVE';
```
Refresh. The row should turn **red** with "OVERLIMIT — 30 min past end",
and within ~2 seconds the total should jump by ₱100.

### 7.9 Cash injection
Cash Register tab → Add Cash Movement → Injection ₱500 with a reason.
Movement appears in the day's list.

### 7.10 Admin Cash Register sees expected variance
Admin tab → Cash Register shows "Expected Cash Now" *including* the
injection. Staff/Manager dashboards do **not** show this.

### 7.11 Close shift mismatch alert
Close the session first (Close Order in Active Sessions tab). Then on the
Cash Register tab, close the shift entering a wrong number (e.g., 1000 below
expected). Admin → Cash Alerts shows a CASH_MISMATCH alert with the
breakdown including the injection.

### 7.12 Admin override
Admin → Cash Overrides → void opening cash with a reason. Refresh. The
shift gate prompts for re-entry.

### 7.13 Analytics
Admin → Analytics → toggle 1 / 7 / 30 days. Bar chart populates.

### 7.14 Receipt email arrived
Check the inbox of the customer email you registered. The receipt should
have arrived within ~5 seconds of the checkout. If not, run:
```bash
supabase functions logs send-receipt --tail
```
The error message will tell you what's wrong (almost always: unverified
sending domain).

### 7.15 Create another user via the admin screen
Admin → Create User → create a staff account. Sign out. Sign in as the
staff user. Confirm only the Staff Dashboard appears (no Analytics tab,
no Cash Overrides tab, no Create User tab).

---

## Step 8 — Troubleshooting cheatsheet

| Symptom | Most likely cause | Fix |
|---|---|---|
| Smoke test shows WARNING with function failures | Column name typo in my SQL | Paste the warnings back to me with the specific function name |
| Login shows "No staff profile found" | Auth user exists but `staff_profiles` row missing | Re-do Step 5.3 with the correct UUID |
| Refresh kicks me to login | `streamlit-cookies-controller` not installed | `pip install streamlit-cookies-controller` then restart Streamlit |
| Sidebar still showing | Browser cached old CSS | Hard refresh: Ctrl+Shift+R or Cmd+Shift+R |
| Customer lookup returns nothing | Email case mismatch | The lookup lowercases input; check the row in `customer_profiles` |
| Active session not turning red | Polling timer not running | Check Streamlit version: `pip show streamlit` — needs ≥1.38 for `st.fragment` |
| Receipt emails not arriving | Unverified Resend sending domain | Verify domain at <https://resend.com/domains> |
| `pg_net` extension errors during migration | Extension disabled in this project | Dashboard → Database → Extensions → enable `pg_net` |
| `pg_cron` errors during migration | Extension disabled in this project | Dashboard → Database → Extensions → enable `pg_cron` |
| Admin "Create User" fails | Missing `SUPABASE_SERVICE_ROLE_KEY` in secrets | Add it to `.streamlit/secrets.toml` |
| Insufficient cash error on checkout | Customer didn't tender enough | Re-enter the cash tendered field with the correct amount |

---

## Step 9 — What's not in this delivery, on purpose

- **Thermal printer support.** Receipts go to email only. When you're ready
  to add USB thermal printing, the receipt-rendering code is isolated in
  `supabase/functions/send-receipt/index.ts` and in `_render_close_flow`
  in `app.py`. A single new function call sends to a `python-escpos`
  receiver. Not a refactor, just an add.
- **Omada Wi-Fi voucher integration.** The receipt payload has no Wi-Fi
  password yet. When your other staff finishes the controller work, add a
  field to `build_receipt_payload` in the SQL migration and to the HTML
  template in the Edge Function.
- **15h zombie-checkout cron.** The watchdog functions exist but aren't
  yet scheduled via cron. To enable nightly sweeps:
  ```sql
  SELECT cron.schedule('watchdog-sweep', '*/15 * * * *', 'SELECT watchdog_run_sweep();');
  ```
- **Parity tests** between the SQL billing math and the Python billing
  math in `app.py`. These existed in the V1 starter but aren't in this
  delivery. Add later if you want regression safety.

---

## Step 10 — Honest disclaimer

I could not run this SQL against a live PostgreSQL instance before sending
it to you — the environment I'm working in doesn't have Postgres available.
What I did instead:

1. Every column reference inside every function uses a table alias. The
   bug that bit us twice before was specifically about unqualified column
   refs in `LANGUAGE sql RETURNS TABLE` functions; aliasing eliminates that
   class of bug.
2. The migration ends with a smoke test that **actually calls** every
   read-only function. PostgreSQL only fully validates `LANGUAGE sql`
   function bodies at call time, so if there's a column-binding error
   anywhere, the smoke test catches it during your migration run, not
   later when the app tries to use it.
3. I hand-audited the column names referenced in `app.py` against the
   schema I'm creating. All 27 RPC signatures and direct table queries
   match.

That said: this is ~1,700 lines of SQL plus ~1,600 lines of Python. The
realistic probability of a first-run bug is non-zero. The smoke test in
Step 2.3 is your firewall — if it prints ALL PASSED, the SQL is sound. If
it prints WARNING, paste it back to me and we fix it in one turn.
