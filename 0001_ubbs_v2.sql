-- =============================================================================
-- 0001_ubbs_v2.sql
--
-- UBBS V2 — CONSOLIDATED MIGRATION (Path 1: clean slate)
--
-- Prerequisite (run separately first):
--     DROP SCHEMA public CASCADE;
--     CREATE SCHEMA public;
--     GRANT ALL ON SCHEMA public TO postgres;
--     GRANT ALL ON SCHEMA public TO public;
--
-- This single file builds the entire UBBS V2 schema:
--   - Tables (12)        - Enums (4)        - Functions (~25)
--   - Triggers (2)       - RLS policies     - Cron jobs (1)
-- Ends with a SMOKE TEST that exercises every function and reports
-- PASS/FAIL via RAISE NOTICE. Watch the Notices panel after running.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- 2. ENUMS
-- ---------------------------------------------------------------------------
DO $enums$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
    CREATE TYPE app_role AS ENUM ('staff', 'manager', 'admin');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transaction_status') THEN
    CREATE TYPE transaction_status AS ENUM ('ACTIVE', 'COMPLETED', 'VOIDED', 'REFUNDED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'shift_status') THEN
    CREATE TYPE shift_status AS ENUM ('OPEN', 'CLOSED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'line_item_kind') THEN
    CREATE TYPE line_item_kind AS ENUM (
      'INITIAL_1HR', 'INITIAL_5HR', 'EXTENSION_MANUAL', 'EXTENSION_AUTO_GRACE'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'refund_status') THEN
    CREATE TYPE refund_status AS ENUM ('PENDING', 'PROCESSED', 'FAILED');
  END IF;
END
$enums$;

-- ---------------------------------------------------------------------------
-- 3. TABLES
-- ---------------------------------------------------------------------------

-- 3.1 staff_profiles — links auth.users to roles + display name.
CREATE TABLE IF NOT EXISTS staff_profiles (
  user_id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT     NOT NULL CHECK (length(trim(display_name)) > 0),
  role         app_role NOT NULL,
  is_active    BOOLEAN  NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3.2 customer_profiles — V2 expanded fields per spec.
CREATE TABLE IF NOT EXISTS customer_profiles (
  customer_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name     TEXT,
  last_name      TEXT,
  email          TEXT,
  phone          TEXT,
  occupation     TEXT,
  school         TEXT,
  consent_given  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  pii_purged_at  TIMESTAMPTZ,
  CONSTRAINT student_must_have_school
    CHECK (occupation IS NULL OR occupation <> 'Student'
           OR (school IS NOT NULL AND length(trim(school)) > 0))
);

CREATE INDEX IF NOT EXISTS idx_customer_profiles_email_lower
  ON customer_profiles (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_customer_profiles_name
  ON customer_profiles (lower(first_name), lower(last_name))
  WHERE first_name IS NOT NULL OR last_name IS NOT NULL;

-- 3.3 pricing_config — one effective row at a time (validated by trigger below).
CREATE TABLE IF NOT EXISTS pricing_config (
  config_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  effective_from           TIMESTAMPTZ NOT NULL,
  effective_until          TIMESTAMPTZ,
  rate_1hr_centavos        BIGINT      NOT NULL CHECK (rate_1hr_centavos > 0),
  rate_5hr_centavos        BIGINT      NOT NULL CHECK (rate_5hr_centavos > 0),
  grace_minutes            INTEGER     NOT NULL CHECK (grace_minutes >= 0),
  auto_extension_centavos  BIGINT      NOT NULL CHECK (auto_extension_centavos > 0),
  auto_extension_minutes   INTEGER     NOT NULL CHECK (auto_extension_minutes > 0),
  max_session_minutes      INTEGER     NOT NULL CHECK (max_session_minutes > 0),
  created_by               UUID,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3.4 shifts — one OPEN at a time, partial unique index enforces.
CREATE TABLE IF NOT EXISTS shifts (
  shift_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opened_by               UUID NOT NULL REFERENCES staff_profiles(user_id),
  opened_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  opening_cash_centavos   BIGINT CHECK (opening_cash_centavos IS NULL OR opening_cash_centavos >= 0),
  closed_by               UUID REFERENCES staff_profiles(user_id),
  closed_at               TIMESTAMPTZ,
  closing_cash_centavos   BIGINT CHECK (closing_cash_centavos IS NULL OR closing_cash_centavos >= 0),
  expected_cash_centavos  BIGINT,
  cash_variance_centavos  BIGINT,
  status                  shift_status NOT NULL DEFAULT 'OPEN',
  opening_voided_at       TIMESTAMPTZ,
  opening_voided_by       UUID REFERENCES staff_profiles(user_id),
  opening_void_reason     TEXT,
  closing_voided_at       TIMESTAMPTZ,
  closing_voided_by       UUID REFERENCES staff_profiles(user_id),
  closing_void_reason     TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS shifts_one_open_at_a_time
  ON shifts(status) WHERE status = 'OPEN';

-- 3.5 transactions — parent record per customer visit.
CREATE TABLE IF NOT EXISTS transactions (
  transaction_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id                UUID NOT NULL REFERENCES shifts(shift_id),
  customer_id             UUID NOT NULL REFERENCES customer_profiles(customer_id),
  created_by              UUID NOT NULL REFERENCES staff_profiles(user_id),
  barcode                 TEXT UNIQUE NOT NULL,
  start_time              TIMESTAMPTZ NOT NULL,
  end_time                TIMESTAMPTZ NOT NULL,
  actual_checkout_time    TIMESTAMPTZ,
  payment_method          TEXT NOT NULL CHECK (payment_method IN ('CASH', 'ONLINE')),
  status                  transaction_status NOT NULL DEFAULT 'ACTIVE',
  final_fee_centavos      BIGINT CHECK (final_fee_centavos IS NULL OR final_fee_centavos >= 0),
  cash_tendered_centavos  BIGINT CHECK (cash_tendered_centavos IS NULL OR cash_tendered_centavos >= 0),
  change_given_centavos   BIGINT CHECK (change_given_centavos IS NULL OR change_given_centavos >= 0),
  void_reason             TEXT,
  voided_by               UUID REFERENCES staff_profiles(user_id),
  voided_at               TIMESTAMPTZ,
  lock_version            INTEGER NOT NULL DEFAULT 0,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT end_after_start CHECK (end_time > start_time),
  CONSTRAINT checkout_after_start CHECK (
    actual_checkout_time IS NULL OR actual_checkout_time >= start_time
  ),
  CONSTRAINT max_session_15h CHECK ((end_time - start_time) <= INTERVAL '15 hours')
);

CREATE INDEX IF NOT EXISTS idx_tx_shift             ON transactions(shift_id);
CREATE INDEX IF NOT EXISTS idx_tx_customer          ON transactions(customer_id);
CREATE INDEX IF NOT EXISTS idx_tx_status_active     ON transactions(status) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_tx_end_time_active   ON transactions(end_time)  WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_tx_start_time_active ON transactions(start_time) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_tx_updated_at        ON transactions(updated_at);

-- 3.6 transaction_line_items — every charged item (initial + extensions + auto).
CREATE TABLE IF NOT EXISTS transaction_line_items (
  line_item_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id    UUID NOT NULL REFERENCES transactions(transaction_id) ON DELETE RESTRICT,
  kind              line_item_kind NOT NULL,
  duration_minutes  INTEGER NOT NULL CHECK (duration_minutes > 0),
  amount_centavos   BIGINT  NOT NULL CHECK (amount_centavos >= 0),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_line_items_tx ON transaction_line_items(transaction_id);

-- 3.7 time_logs — append-only event journal per transaction.
CREATE TABLE IF NOT EXISTS time_logs (
  log_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  UUID NOT NULL REFERENCES transactions(transaction_id),
  event_type      TEXT NOT NULL CHECK (event_type IN (
    'SESSION_START', 'EXTENSION_APPLIED', 'AUTO_EXTENSION', 'SESSION_END',
    'VOID', 'REFUND_REQUESTED', 'FORCE_CHECKOUT'
  )),
  actor_id        UUID,
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_time_logs_tx ON time_logs(transaction_id, created_at);

-- 3.8 cash_movements — injections and payouts during a shift.
CREATE TABLE IF NOT EXISTS cash_movements (
  movement_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id        UUID NOT NULL REFERENCES shifts(shift_id),
  kind            TEXT NOT NULL CHECK (kind IN ('INJECTION', 'PAYOUT')),
  amount_centavos BIGINT NOT NULL CHECK (amount_centavos > 0),
  reason          TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  actor_id        UUID NOT NULL REFERENCES staff_profiles(user_id),
  actor_role      app_role NOT NULL,
  voided          BOOLEAN NOT NULL DEFAULT FALSE,
  voided_by       UUID REFERENCES staff_profiles(user_id),
  voided_at       TIMESTAMPTZ,
  void_reason     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    (voided = FALSE AND voided_by IS NULL AND voided_at IS NULL AND void_reason IS NULL)
    OR
    (voided = TRUE  AND voided_by IS NOT NULL AND voided_at IS NOT NULL AND void_reason IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_cash_movements_shift  ON cash_movements(shift_id, created_at);
CREATE INDEX IF NOT EXISTS idx_cash_movements_active ON cash_movements(shift_id) WHERE voided = FALSE;

-- 3.9 shift_cash_audit — full history of every cash-entry action.
CREATE TABLE IF NOT EXISTS shift_cash_audit (
  audit_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id        UUID NOT NULL REFERENCES shifts(shift_id),
  action          TEXT NOT NULL CHECK (action IN
                    ('OPEN', 'OPEN_VOID', 'OPEN_REDO', 'CLOSE', 'CLOSE_VOID', 'CLOSE_REDO')),
  amount_centavos BIGINT,
  actor_id        UUID NOT NULL REFERENCES staff_profiles(user_id),
  actor_role      app_role NOT NULL,
  reason          TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    (action IN ('OPEN', 'OPEN_REDO', 'CLOSE', 'CLOSE_REDO') AND amount_centavos IS NOT NULL)
    OR
    (action IN ('OPEN_VOID', 'CLOSE_VOID') AND amount_centavos IS NULL
     AND reason IS NOT NULL AND length(trim(reason)) > 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_shift_cash_audit_shift ON shift_cash_audit(shift_id, created_at);

-- 3.10 audit_log — generic actor-action-entity audit trail.
CREATE TABLE IF NOT EXISTS audit_log (
  audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id     UUID,
  actor_role   app_role,
  action       TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    UUID,
  before       JSONB,
  after        JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity_type, entity_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor  ON audit_log(actor_id, created_at);

-- 3.11 admin_alerts — silent admin notifications (cash mismatch, zombies, etc.).
CREATE TABLE IF NOT EXISTS admin_alerts (
  alert_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type       TEXT NOT NULL,
  severity         TEXT NOT NULL CHECK (severity IN ('INFO', 'WARN', 'CRITICAL')),
  entity_type      TEXT NOT NULL,
  entity_id        UUID,
  payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledged_by  UUID REFERENCES staff_profiles(user_id),
  acknowledged_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_admin_alerts_unack
  ON admin_alerts(created_at DESC) WHERE acknowledged_at IS NULL;

-- 3.12 refunds — V1 carry-over, manager+ approves.
CREATE TABLE IF NOT EXISTS refunds (
  refund_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id   UUID NOT NULL REFERENCES transactions(transaction_id),
  requested_by     UUID NOT NULL REFERENCES staff_profiles(user_id),
  requested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  amount_centavos  BIGINT NOT NULL CHECK (amount_centavos > 0),
  reason           TEXT   NOT NULL,
  status           refund_status NOT NULL DEFAULT 'PENDING',
  processed_by     UUID REFERENCES staff_profiles(user_id),
  processed_at     TIMESTAMPTZ,
  failure_reason   TEXT
);

CREATE INDEX IF NOT EXISTS idx_refunds_tx ON refunds(transaction_id);

-- ---------------------------------------------------------------------------
-- 4. AUTH HELPER FUNCTIONS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auth_role()
RETURNS app_role
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_role app_role;
BEGIN
  SELECT sp.role INTO v_role
    FROM staff_profiles sp
   WHERE sp.user_id = auth.uid() AND sp.is_active = TRUE;
  RETURN v_role;
END;
$fn$;

CREATE OR REPLACE FUNCTION auth_role_at_least(p_min app_role)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_role app_role := auth_role();
  v_rank_user INTEGER;
  v_rank_min  INTEGER;
BEGIN
  IF v_role IS NULL THEN RETURN FALSE; END IF;
  v_rank_user := CASE v_role WHEN 'staff' THEN 0 WHEN 'manager' THEN 1 WHEN 'admin' THEN 2 END;
  v_rank_min  := CASE p_min  WHEN 'staff' THEN 0 WHEN 'manager' THEN 1 WHEN 'admin' THEN 2 END;
  RETURN v_rank_user >= v_rank_min;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. BARCODE GENERATOR
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_barcode()
RETURNS TEXT
LANGUAGE plpgsql AS $fn$
DECLARE
  v_barcode TEXT;
  v_attempts INTEGER := 0;
BEGIN
  LOOP
    v_barcode := 'UBBS-' || to_char(NOW(), 'YYMMDD') || '-' || lpad(floor(random() * 10000)::TEXT, 4, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM transactions t WHERE t.barcode = v_barcode);
    v_attempts := v_attempts + 1;
    IF v_attempts > 20 THEN
      RAISE EXCEPTION 'Could not generate unique barcode after 20 attempts';
    END IF;
  END LOOP;
  RETURN v_barcode;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. PRICING HELPER — read current effective config row.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION billing_current_pricing()
RETURNS pricing_config
LANGUAGE sql STABLE
SET search_path = public AS $fn$
  SELECT pc.* FROM pricing_config pc
   WHERE pc.effective_from <= NOW()
     AND (pc.effective_until IS NULL OR pc.effective_until > NOW())
   ORDER BY pc.effective_from DESC LIMIT 1;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. MUTATOR FUNCTIONS
-- ---------------------------------------------------------------------------

-- 7.1 open_shift
CREATE OR REPLACE FUNCTION open_shift(p_opening_cash_centavos BIGINT)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id  UUID := auth.uid();
  v_role     app_role := auth_role();
  v_shift_id UUID;
  v_existing_open UUID;
  v_is_redo  BOOLEAN := FALSE;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: open_shift requires staff role';
  END IF;
  IF p_opening_cash_centavos < 0 THEN
    RAISE EXCEPTION 'opening_cash_centavos must be >= 0';
  END IF;

  SELECT s.shift_id INTO v_existing_open
    FROM shifts s
   WHERE s.status = 'OPEN' AND s.opening_cash_centavos IS NULL
   FOR UPDATE;

  IF v_existing_open IS NOT NULL THEN
    UPDATE shifts
       SET opening_cash_centavos = p_opening_cash_centavos,
           opening_voided_at = NULL,
           opening_voided_by = NULL,
           opening_void_reason = NULL
     WHERE shift_id = v_existing_open;
    v_shift_id := v_existing_open;
    v_is_redo := TRUE;
  ELSE
    INSERT INTO shifts (opened_by, opening_cash_centavos, status)
    VALUES (v_user_id, p_opening_cash_centavos, 'OPEN')
    RETURNING shift_id INTO v_shift_id;
  END IF;

  INSERT INTO shift_cash_audit (shift_id, action, amount_centavos, actor_id, actor_role)
  VALUES (v_shift_id,
          CASE WHEN v_is_redo THEN 'OPEN_REDO' ELSE 'OPEN' END,
          p_opening_cash_centavos, v_user_id, v_role);

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, after)
  VALUES (v_user_id, v_role,
          CASE WHEN v_is_redo THEN 'OPEN_SHIFT_REDO' ELSE 'OPEN_SHIFT' END,
          'shift', v_shift_id,
          jsonb_build_object('opening_cash_centavos', p_opening_cash_centavos));

  RETURN v_shift_id;
END;
$fn$;

-- 7.2 register_customer
CREATE OR REPLACE FUNCTION register_customer(
  p_first_name TEXT,
  p_last_name  TEXT,
  p_email      TEXT,
  p_phone      TEXT,
  p_occupation TEXT,
  p_school     TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_customer_id UUID;
  v_existing    UUID;
BEGIN
  IF p_first_name IS NULL OR length(trim(p_first_name)) = 0 THEN
    RAISE EXCEPTION 'First name is required';
  END IF;
  IF p_last_name IS NULL OR length(trim(p_last_name)) = 0 THEN
    RAISE EXCEPTION 'Last name is required';
  END IF;
  IF p_email IS NULL OR length(trim(p_email)) = 0 THEN
    RAISE EXCEPTION 'Email is required';
  END IF;
  IF p_occupation = 'Student' AND (p_school IS NULL OR length(trim(p_school)) = 0) THEN
    RAISE EXCEPTION 'School is required for student occupation';
  END IF;

  SELECT cp.customer_id INTO v_existing
    FROM customer_profiles cp
   WHERE lower(cp.email) = lower(trim(p_email))
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    UPDATE customer_profiles
       SET first_name = trim(p_first_name),
           last_name  = trim(p_last_name),
           phone      = COALESCE(NULLIF(trim(p_phone), ''), phone),
           occupation = COALESCE(NULLIF(trim(p_occupation), ''), occupation),
           school     = COALESCE(NULLIF(trim(p_school), ''), school)
     WHERE customer_id = v_existing;
    RETURN v_existing;
  END IF;

  INSERT INTO customer_profiles (
    first_name, last_name, email, phone, occupation, school
  ) VALUES (
    trim(p_first_name), trim(p_last_name), lower(trim(p_email)),
    NULLIF(trim(p_phone), ''), NULLIF(trim(p_occupation), ''), NULLIF(trim(p_school), '')
  )
  RETURNING customer_id INTO v_customer_id;

  RETURN v_customer_id;
END;
$fn$;

-- 7.3 find_customer_by_email — table-aliased to avoid the column-binding bug.
CREATE OR REPLACE FUNCTION find_customer_by_email(p_email TEXT)
RETURNS TABLE (
  customer_id UUID,
  first_name  TEXT,
  last_name   TEXT,
  email       TEXT,
  phone       TEXT,
  occupation  TEXT,
  school      TEXT
)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
  SELECT cp.customer_id, cp.first_name, cp.last_name, cp.email,
         cp.phone, cp.occupation, cp.school
    FROM customer_profiles cp
   WHERE lower(cp.email) = lower(trim(p_email))
   LIMIT 1;
$fn$;

-- 7.4 start_session
CREATE OR REPLACE FUNCTION start_session(
  p_customer_id     UUID,
  p_initial_kind    line_item_kind,
  p_payment_method  TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id   UUID := auth.uid();
  v_role      app_role := auth_role();
  v_shift_id  UUID;
  v_tx_id     UUID;
  v_now       TIMESTAMPTZ := NOW();
  v_duration  INTEGER;
  v_amount    BIGINT;
  v_pricing   pricing_config;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: start_session requires staff role';
  END IF;
  IF p_initial_kind NOT IN ('INITIAL_1HR', 'INITIAL_5HR') THEN
    RAISE EXCEPTION 'Invalid initial kind: %', p_initial_kind;
  END IF;
  IF p_payment_method NOT IN ('CASH', 'ONLINE') THEN
    RAISE EXCEPTION 'Invalid payment method: %', p_payment_method;
  END IF;

  SELECT s.shift_id INTO v_shift_id
    FROM shifts s
   WHERE s.status = 'OPEN' AND s.opening_cash_centavos IS NOT NULL
   LIMIT 1;
  IF v_shift_id IS NULL THEN
    RAISE EXCEPTION 'No open shift with opening cash recorded';
  END IF;

  v_pricing := billing_current_pricing();
  IF v_pricing IS NULL THEN
    RAISE EXCEPTION 'No effective pricing config';
  END IF;

  IF p_initial_kind = 'INITIAL_1HR' THEN
    v_duration := 60;  v_amount := v_pricing.rate_1hr_centavos;
  ELSE
    v_duration := 300; v_amount := v_pricing.rate_5hr_centavos;
  END IF;

  INSERT INTO transactions (
    shift_id, customer_id, created_by, barcode, start_time, end_time,
    payment_method, status
  ) VALUES (
    v_shift_id, p_customer_id, v_user_id, generate_barcode(),
    v_now, v_now + (v_duration || ' minutes')::INTERVAL,
    p_payment_method, 'ACTIVE'
  ) RETURNING transaction_id INTO v_tx_id;

  INSERT INTO transaction_line_items (transaction_id, kind, duration_minutes, amount_centavos)
  VALUES (v_tx_id, p_initial_kind, v_duration, v_amount);

  INSERT INTO time_logs (transaction_id, event_type, actor_id, metadata)
  VALUES (v_tx_id, 'SESSION_START', v_user_id,
          jsonb_build_object('kind', p_initial_kind, 'amount_centavos', v_amount));

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, after)
  VALUES (v_user_id, v_role, 'START_SESSION', 'transaction', v_tx_id,
          (SELECT to_jsonb(t.*) FROM transactions t WHERE t.transaction_id = v_tx_id));

  RETURN v_tx_id;
END;
$fn$;

-- 7.5 extend_session — used for in-window extensions (now < contracted_end).
CREATE OR REPLACE FUNCTION extend_session(
  p_transaction_id   UUID,
  p_duration_minutes INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id  UUID := auth.uid();
  v_role     app_role := auth_role();
  v_tx       transactions%ROWTYPE;
  v_amount   BIGINT;
  v_kind     line_item_kind;
  v_pricing  pricing_config;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: extend_session requires staff role';
  END IF;
  IF p_duration_minutes NOT IN (60, 300) THEN
    RAISE EXCEPTION 'duration_minutes must be 60 or 300';
  END IF;

  SELECT * INTO v_tx FROM transactions t
    WHERE t.transaction_id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction % not found', p_transaction_id;
  END IF;
  IF v_tx.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Transaction is not ACTIVE (status=%)', v_tx.status;
  END IF;

  v_pricing := billing_current_pricing();
  IF p_duration_minutes = 60 THEN
    v_amount := v_pricing.rate_1hr_centavos; v_kind := 'INITIAL_1HR';
  ELSE
    v_amount := v_pricing.rate_5hr_centavos; v_kind := 'INITIAL_5HR';
  END IF;

  UPDATE transactions
     SET end_time     = end_time + (p_duration_minutes || ' minutes')::INTERVAL,
         lock_version = lock_version + 1,
         updated_at   = NOW()
   WHERE transaction_id = p_transaction_id;

  INSERT INTO transaction_line_items (transaction_id, kind, duration_minutes, amount_centavos)
  VALUES (p_transaction_id, 'EXTENSION_MANUAL', p_duration_minutes, v_amount);

  INSERT INTO time_logs (transaction_id, event_type, actor_id, metadata)
  VALUES (p_transaction_id, 'EXTENSION_APPLIED', v_user_id,
          jsonb_build_object('duration_minutes', p_duration_minutes,
                             'amount_centavos', v_amount, 'kind', v_kind));

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'EXTEND_SESSION', 'transaction', p_transaction_id,
          to_jsonb(v_tx),
          (SELECT to_jsonb(t.*) FROM transactions t WHERE t.transaction_id = p_transaction_id));

  RETURN TRUE;
END;
$fn$;

-- 7.6 apply_auto_extensions_if_due — runs every checkout + watchdog sweep.
CREATE OR REPLACE FUNCTION apply_auto_extensions_if_due(p_transaction_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_tx              transactions%ROWTYPE;
  v_pricing         pricing_config;
  v_applied_count   INTEGER := 0;
  v_contracted_end  TIMESTAMPTZ;
  v_minutes_past    INTEGER;
  v_expected_auto   INTEGER;
  v_already_auto    INTEGER;
  v_pending         INTEGER;
  v_i               INTEGER;
BEGIN
  SELECT * INTO v_tx FROM transactions t
    WHERE t.transaction_id = p_transaction_id FOR UPDATE;
  IF NOT FOUND OR v_tx.status <> 'ACTIVE' THEN
    RETURN 0;
  END IF;

  v_pricing := billing_current_pricing();

  SELECT COUNT(*) INTO v_already_auto
    FROM transaction_line_items li
   WHERE li.transaction_id = p_transaction_id
     AND li.kind = 'EXTENSION_AUTO_GRACE';

  -- contracted_end = end_time minus auto-extensions already applied.
  v_contracted_end := v_tx.end_time
    - (v_already_auto * v_pricing.auto_extension_minutes || ' minutes')::INTERVAL;

  v_minutes_past := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (NOW() - v_contracted_end)) / 60.0))::INTEGER;

  IF v_minutes_past <= v_pricing.grace_minutes THEN
    RETURN 0;
  END IF;

  v_expected_auto := GREATEST(1, CEIL(v_minutes_past::NUMERIC / v_pricing.auto_extension_minutes))::INTEGER;
  v_pending := v_expected_auto - v_already_auto;

  v_i := 0;
  WHILE v_i < v_pending LOOP
    UPDATE transactions
       SET end_time     = end_time + (v_pricing.auto_extension_minutes || ' minutes')::INTERVAL,
           lock_version = lock_version + 1,
           updated_at   = NOW()
     WHERE transaction_id = p_transaction_id;

    INSERT INTO transaction_line_items (transaction_id, kind, duration_minutes, amount_centavos)
    VALUES (p_transaction_id, 'EXTENSION_AUTO_GRACE',
            v_pricing.auto_extension_minutes, v_pricing.auto_extension_centavos);

    INSERT INTO time_logs (transaction_id, event_type, metadata)
    VALUES (p_transaction_id, 'AUTO_EXTENSION',
            jsonb_build_object('amount_centavos', v_pricing.auto_extension_centavos));

    v_applied_count := v_applied_count + 1;
    v_i := v_i + 1;
  END LOOP;

  RETURN v_applied_count;
END;
$fn$;

-- 7.7 checkout_session — accepts cash tendered for change calculator.
CREATE OR REPLACE FUNCTION checkout_session(
  p_transaction_id        UUID,
  p_cash_tendered_centavos BIGINT DEFAULT NULL
)
RETURNS TABLE (
  final_fee_centavos  BIGINT,
  change_due_centavos BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id     UUID := auth.uid();
  v_role        app_role := auth_role();
  v_tx          transactions%ROWTYPE;
  v_line_total  BIGINT;
  v_change      BIGINT;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: checkout_session requires staff role';
  END IF;

  SELECT * INTO v_tx FROM transactions t
    WHERE t.transaction_id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction % not found', p_transaction_id;
  END IF;
  IF v_tx.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'Transaction is not ACTIVE (status=%)', v_tx.status;
  END IF;

  PERFORM apply_auto_extensions_if_due(p_transaction_id);

  SELECT COALESCE(SUM(li.amount_centavos), 0) INTO v_line_total
    FROM transaction_line_items li
   WHERE li.transaction_id = p_transaction_id;

  IF v_tx.payment_method = 'CASH' THEN
    IF p_cash_tendered_centavos IS NULL THEN
      RAISE EXCEPTION 'Cash tendered amount is required for cash payment';
    END IF;
    IF p_cash_tendered_centavos < v_line_total THEN
      RAISE EXCEPTION 'Cash tendered (%) is less than amount due (%)',
                      p_cash_tendered_centavos, v_line_total;
    END IF;
    v_change := p_cash_tendered_centavos - v_line_total;
  ELSE
    v_change := NULL;
  END IF;

  UPDATE transactions
     SET status                  = 'COMPLETED',
         actual_checkout_time    = NOW(),
         final_fee_centavos      = v_line_total,
         cash_tendered_centavos  = p_cash_tendered_centavos,
         change_given_centavos   = v_change,
         lock_version            = lock_version + 1,
         updated_at              = NOW()
   WHERE transaction_id = p_transaction_id;

  INSERT INTO time_logs (transaction_id, event_type, actor_id, metadata)
  VALUES (p_transaction_id, 'SESSION_END', v_user_id,
          jsonb_build_object(
            'final_fee_centavos', v_line_total,
            'cash_tendered_centavos', p_cash_tendered_centavos,
            'change_given_centavos', v_change
          ));

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'CHECKOUT_SESSION', 'transaction', p_transaction_id,
          to_jsonb(v_tx),
          (SELECT to_jsonb(t.*) FROM transactions t WHERE t.transaction_id = p_transaction_id));

  RETURN QUERY SELECT v_line_total, v_change;
END;
$fn$;

-- 7.8 void_session — manager+ only.
CREATE OR REPLACE FUNCTION void_session(
  p_transaction_id UUID,
  p_reason         TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id UUID := auth.uid();
  v_role    app_role := auth_role();
  v_tx      transactions%ROWTYPE;
BEGIN
  IF NOT auth_role_at_least('manager') THEN
    RAISE EXCEPTION 'Unauthorized: void_session requires manager role';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'Void reason is required';
  END IF;

  SELECT * INTO v_tx FROM transactions t
    WHERE t.transaction_id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction % not found', p_transaction_id;
  END IF;
  IF v_tx.status NOT IN ('ACTIVE', 'COMPLETED') THEN
    RAISE EXCEPTION 'Cannot void transaction with status %', v_tx.status;
  END IF;

  UPDATE transactions
     SET status       = 'VOIDED',
         void_reason  = p_reason,
         voided_by    = v_user_id,
         voided_at    = NOW(),
         lock_version = lock_version + 1,
         updated_at   = NOW()
   WHERE transaction_id = p_transaction_id;

  INSERT INTO time_logs (transaction_id, event_type, actor_id, metadata)
  VALUES (p_transaction_id, 'VOID', v_user_id, jsonb_build_object('reason', p_reason));

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'VOID_SESSION', 'transaction', p_transaction_id,
          to_jsonb(v_tx),
          (SELECT to_jsonb(t.*) FROM transactions t WHERE t.transaction_id = p_transaction_id));

  RETURN TRUE;
END;
$fn$;

-- 7.9 close_shift
CREATE OR REPLACE FUNCTION close_shift(
  p_shift_id              UUID,
  p_closing_cash_centavos BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id      UUID := auth.uid();
  v_role         app_role := auth_role();
  v_shift        shifts%ROWTYPE;
  v_active_count INTEGER;
  v_variance     BIGINT;
  v_is_redo      BOOLEAN := FALSE;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: close_shift requires staff role';
  END IF;
  IF p_closing_cash_centavos < 0 THEN
    RAISE EXCEPTION 'closing_cash_centavos must be >= 0';
  END IF;

  SELECT * INTO v_shift FROM shifts s WHERE s.shift_id = p_shift_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift % not found', p_shift_id;
  END IF;
  IF v_shift.opening_cash_centavos IS NULL THEN
    RAISE EXCEPTION 'Cannot close shift: opening cash not recorded';
  END IF;

  IF v_shift.status = 'CLOSED' AND v_shift.closing_cash_centavos IS NULL THEN
    v_is_redo := TRUE;
  ELSIF v_shift.status <> 'OPEN' THEN
    RAISE EXCEPTION 'Shift % is not OPEN (status=%)', p_shift_id, v_shift.status;
  END IF;

  SELECT COUNT(*) INTO v_active_count FROM transactions t
   WHERE t.shift_id = p_shift_id AND t.status = 'ACTIVE';
  IF v_active_count > 0 THEN
    RAISE EXCEPTION 'Cannot close shift: % active sessions remain', v_active_count;
  END IF;

  UPDATE shifts
     SET status                = 'CLOSED',
         closed_by             = COALESCE(closed_by, v_user_id),
         closed_at             = COALESCE(closed_at, NOW()),
         closing_cash_centavos = p_closing_cash_centavos,
         closing_voided_at     = NULL,
         closing_voided_by     = NULL,
         closing_void_reason   = NULL
   WHERE shift_id = p_shift_id;

  PERFORM watchdog_verify_shift_cash(p_shift_id);

  SELECT s.cash_variance_centavos INTO v_variance
    FROM shifts s WHERE s.shift_id = p_shift_id;

  INSERT INTO shift_cash_audit (shift_id, action, amount_centavos, actor_id, actor_role)
  VALUES (p_shift_id,
          CASE WHEN v_is_redo THEN 'CLOSE_REDO' ELSE 'CLOSE' END,
          p_closing_cash_centavos, v_user_id, v_role);

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role,
          CASE WHEN v_is_redo THEN 'CLOSE_SHIFT_REDO' ELSE 'CLOSE_SHIFT' END,
          'shift', p_shift_id,
          to_jsonb(v_shift),
          (SELECT to_jsonb(s.*) FROM shifts s WHERE s.shift_id = p_shift_id));

  RETURN v_variance;
END;
$fn$;

-- 7.10 register_cash_movement
CREATE OR REPLACE FUNCTION register_cash_movement(
  p_kind            TEXT,
  p_amount_centavos BIGINT,
  p_reason          TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id     UUID := auth.uid();
  v_role        app_role := auth_role();
  v_shift_id    UUID;
  v_movement_id UUID;
BEGIN
  IF NOT auth_role_at_least('staff') THEN
    RAISE EXCEPTION 'Unauthorized: register_cash_movement requires staff role';
  END IF;
  IF p_kind NOT IN ('INJECTION', 'PAYOUT') THEN
    RAISE EXCEPTION 'Invalid kind %, must be INJECTION or PAYOUT', p_kind;
  END IF;
  IF p_amount_centavos <= 0 THEN
    RAISE EXCEPTION 'amount_centavos must be > 0';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'reason is required';
  END IF;

  SELECT s.shift_id INTO v_shift_id
    FROM shifts s
   WHERE s.status = 'OPEN' AND s.opening_cash_centavos IS NOT NULL
   FOR UPDATE;
  IF v_shift_id IS NULL THEN
    RAISE EXCEPTION 'No open shift with opening cash recorded';
  END IF;

  INSERT INTO cash_movements (
    shift_id, kind, amount_centavos, reason, actor_id, actor_role
  ) VALUES (
    v_shift_id, p_kind, p_amount_centavos, p_reason, v_user_id, v_role
  ) RETURNING movement_id INTO v_movement_id;

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, after)
  VALUES (v_user_id, v_role, 'CASH_' || p_kind, 'cash_movement', v_movement_id,
          jsonb_build_object(
            'shift_id', v_shift_id, 'kind', p_kind,
            'amount_centavos', p_amount_centavos, 'reason', p_reason
          ));

  RETURN v_movement_id;
END;
$fn$;

-- 7.11 void_cash_movement (admin only)
CREATE OR REPLACE FUNCTION void_cash_movement(
  p_movement_id UUID,
  p_reason      TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id  UUID := auth.uid();
  v_role     app_role := auth_role();
  v_movement cash_movements%ROWTYPE;
BEGIN
  IF NOT auth_role_at_least('admin') THEN
    RAISE EXCEPTION 'Unauthorized: void_cash_movement requires admin role';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'void reason is required';
  END IF;

  SELECT * INTO v_movement FROM cash_movements cm
    WHERE cm.movement_id = p_movement_id FOR UPDATE;
  IF NOT FOUND OR v_movement.voided THEN
    RETURN FALSE;
  END IF;

  UPDATE cash_movements
     SET voided      = TRUE,
         voided_by   = v_user_id,
         voided_at   = NOW(),
         void_reason = p_reason
   WHERE movement_id = p_movement_id;

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'VOID_CASH_MOVEMENT', 'cash_movement', p_movement_id,
          to_jsonb(v_movement),
          (SELECT to_jsonb(cm.*) FROM cash_movements cm WHERE cm.movement_id = p_movement_id));

  RETURN TRUE;
END;
$fn$;

-- 7.12 admin_void_opening_cash
CREATE OR REPLACE FUNCTION admin_void_opening_cash(
  p_shift_id UUID,
  p_reason   TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id UUID := auth.uid();
  v_role    app_role := auth_role();
  v_shift   shifts%ROWTYPE;
BEGIN
  IF NOT auth_role_at_least('admin') THEN
    RAISE EXCEPTION 'Unauthorized: admin_void_opening_cash requires admin role';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'void reason is required';
  END IF;

  SELECT * INTO v_shift FROM shifts s WHERE s.shift_id = p_shift_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift % not found', p_shift_id;
  END IF;
  IF v_shift.opening_cash_centavos IS NULL THEN
    RAISE EXCEPTION 'Opening cash is already void / not set';
  END IF;

  UPDATE shifts
     SET opening_cash_centavos = NULL,
         opening_voided_at     = NOW(),
         opening_voided_by     = v_user_id,
         opening_void_reason   = p_reason
   WHERE shift_id = p_shift_id;

  INSERT INTO shift_cash_audit (shift_id, action, actor_id, actor_role, reason)
  VALUES (p_shift_id, 'OPEN_VOID', v_user_id, v_role, p_reason);

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'ADMIN_VOID_OPENING_CASH', 'shift', p_shift_id,
          to_jsonb(v_shift),
          (SELECT to_jsonb(s.*) FROM shifts s WHERE s.shift_id = p_shift_id));

  RETURN TRUE;
END;
$fn$;

-- 7.13 admin_void_closing_cash
CREATE OR REPLACE FUNCTION admin_void_closing_cash(
  p_shift_id UUID,
  p_reason   TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_user_id UUID := auth.uid();
  v_role    app_role := auth_role();
  v_shift   shifts%ROWTYPE;
BEGIN
  IF NOT auth_role_at_least('admin') THEN
    RAISE EXCEPTION 'Unauthorized: admin_void_closing_cash requires admin role';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'void reason is required';
  END IF;

  SELECT * INTO v_shift FROM shifts s WHERE s.shift_id = p_shift_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shift % not found', p_shift_id;
  END IF;
  IF v_shift.closing_cash_centavos IS NULL THEN
    RAISE EXCEPTION 'Closing cash is already void / not set';
  END IF;

  UPDATE shifts
     SET closing_cash_centavos  = NULL,
         expected_cash_centavos = NULL,
         cash_variance_centavos = NULL,
         closing_voided_at      = NOW(),
         closing_voided_by      = v_user_id,
         closing_void_reason    = p_reason
   WHERE shift_id = p_shift_id;

  INSERT INTO shift_cash_audit (shift_id, action, actor_id, actor_role, reason)
  VALUES (p_shift_id, 'CLOSE_VOID', v_user_id, v_role, p_reason);

  INSERT INTO audit_log (actor_id, actor_role, action, entity_type, entity_id, before, after)
  VALUES (v_user_id, v_role, 'ADMIN_VOID_CLOSING_CASH', 'shift', p_shift_id,
          to_jsonb(v_shift),
          (SELECT to_jsonb(s.*) FROM shifts s WHERE s.shift_id = p_shift_id));

  RETURN TRUE;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. WATCHDOG FUNCTIONS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION watchdog_verify_shift_cash(p_shift_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_shift          shifts%ROWTYPE;
  v_cash_revenue   BIGINT;
  v_injections     BIGINT;
  v_payouts        BIGINT;
  v_expected       BIGINT;
  v_variance       BIGINT;
BEGIN
  SELECT * INTO v_shift FROM shifts s WHERE s.shift_id = p_shift_id FOR UPDATE;
  IF NOT FOUND OR v_shift.status <> 'CLOSED' THEN
    RETURN FALSE;
  END IF;
  IF v_shift.opening_cash_centavos IS NULL OR v_shift.closing_cash_centavos IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT COALESCE(SUM(t.final_fee_centavos), 0) INTO v_cash_revenue
    FROM transactions t
   WHERE t.shift_id = p_shift_id
     AND t.payment_method = 'CASH'
     AND t.status = 'COMPLETED';

  SELECT COALESCE(SUM(cm.amount_centavos), 0) INTO v_injections
    FROM cash_movements cm
   WHERE cm.shift_id = p_shift_id AND cm.kind = 'INJECTION' AND cm.voided = FALSE;

  SELECT COALESCE(SUM(cm.amount_centavos), 0) INTO v_payouts
    FROM cash_movements cm
   WHERE cm.shift_id = p_shift_id AND cm.kind = 'PAYOUT' AND cm.voided = FALSE;

  v_expected := v_shift.opening_cash_centavos + v_cash_revenue + v_injections - v_payouts;
  v_variance := v_shift.closing_cash_centavos - v_expected;

  UPDATE shifts
     SET expected_cash_centavos = v_expected,
         cash_variance_centavos = v_variance
   WHERE shift_id = p_shift_id;

  IF v_variance <> 0 THEN
    INSERT INTO admin_alerts (alert_type, severity, entity_type, entity_id, payload)
    VALUES (
      'CASH_MISMATCH',
      CASE
        WHEN ABS(v_variance) >= 50000 THEN 'CRITICAL'
        WHEN ABS(v_variance) >= 10000 THEN 'WARN'
        ELSE 'INFO'
      END,
      'shift', p_shift_id,
      jsonb_build_object(
        'opening_cash_centavos',  v_shift.opening_cash_centavos,
        'closing_cash_centavos',  v_shift.closing_cash_centavos,
        'expected_cash_centavos', v_expected,
        'cash_revenue_centavos',  v_cash_revenue,
        'injections_centavos',    v_injections,
        'payouts_centavos',       v_payouts,
        'variance_centavos',      v_variance
      )
    );
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$fn$;

CREATE OR REPLACE FUNCTION watchdog_find_zombie_sessions(p_hours INTEGER DEFAULT 15)
RETURNS TABLE (
  transaction_id UUID,
  hours_open     NUMERIC
)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
  SELECT t.transaction_id,
         (EXTRACT(EPOCH FROM (NOW() - t.start_time)) / 3600.0)::NUMERIC
    FROM transactions t
   WHERE t.status = 'ACTIVE'
     AND t.start_time < NOW() - (p_hours || ' hours')::INTERVAL;
$fn$;

CREATE OR REPLACE FUNCTION watchdog_force_checkout_at_cap(p_transaction_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_tx       transactions%ROWTYPE;
  v_total    BIGINT;
BEGIN
  SELECT * INTO v_tx FROM transactions t
    WHERE t.transaction_id = p_transaction_id FOR UPDATE;
  IF NOT FOUND OR v_tx.status <> 'ACTIVE' THEN
    RETURN FALSE;
  END IF;

  PERFORM apply_auto_extensions_if_due(p_transaction_id);

  SELECT COALESCE(SUM(li.amount_centavos), 0) INTO v_total
    FROM transaction_line_items li
   WHERE li.transaction_id = p_transaction_id;

  UPDATE transactions
     SET status                = 'COMPLETED',
         actual_checkout_time  = NOW(),
         final_fee_centavos    = v_total,
         lock_version          = lock_version + 1,
         updated_at            = NOW()
   WHERE transaction_id = p_transaction_id;

  INSERT INTO time_logs (transaction_id, event_type, metadata)
  VALUES (p_transaction_id, 'FORCE_CHECKOUT',
          jsonb_build_object('reason', '15h cap', 'final_fee_centavos', v_total));

  INSERT INTO admin_alerts (alert_type, severity, entity_type, entity_id, payload)
  VALUES ('ZOMBIE_FORCE_CHECKOUT', 'CRITICAL', 'transaction', p_transaction_id,
          jsonb_build_object('final_fee_centavos', v_total));

  RETURN TRUE;
END;
$fn$;

CREATE OR REPLACE FUNCTION watchdog_run_sweep()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_count INTEGER := 0;
  v_tx    RECORD;
BEGIN
  FOR v_tx IN SELECT * FROM watchdog_find_zombie_sessions(15) LOOP
    IF watchdog_force_checkout_at_cap(v_tx.transaction_id) THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 9. QUERY FUNCTIONS — all use table aliases (the column-binding fix).
-- ---------------------------------------------------------------------------

-- 9.1 preview_shift_cash_expected (admin only).
CREATE OR REPLACE FUNCTION preview_shift_cash_expected(p_shift_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
DECLARE
  v_opening    BIGINT;
  v_cash_rev   BIGINT;
  v_inject     BIGINT;
  v_payout     BIGINT;
BEGIN
  IF NOT auth_role_at_least('admin') THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(s.opening_cash_centavos, 0) INTO v_opening
    FROM shifts s WHERE s.shift_id = p_shift_id;

  SELECT COALESCE(SUM(t.final_fee_centavos), 0) INTO v_cash_rev
    FROM transactions t
   WHERE t.shift_id = p_shift_id AND t.payment_method = 'CASH' AND t.status = 'COMPLETED';

  SELECT COALESCE(SUM(cm.amount_centavos), 0) INTO v_inject
    FROM cash_movements cm
   WHERE cm.shift_id = p_shift_id AND cm.kind = 'INJECTION' AND cm.voided = FALSE;

  SELECT COALESCE(SUM(cm.amount_centavos), 0) INTO v_payout
    FROM cash_movements cm
   WHERE cm.shift_id = p_shift_id AND cm.kind = 'PAYOUT' AND cm.voided = FALSE;

  RETURN v_opening + v_cash_rev + v_inject - v_payout;
END;
$fn$;

-- 9.2 analytics_revenue_rollup — TABLE-ALIASED.
CREATE OR REPLACE FUNCTION analytics_revenue_rollup(p_days INTEGER)
RETURNS TABLE (
  bucket_date      DATE,
  tx_count         BIGINT,
  revenue_centavos BIGINT
)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
  SELECT
    (t.start_time AT TIME ZONE 'Asia/Manila')::DATE AS bucket_date,
    COUNT(*)::BIGINT                                AS tx_count,
    COALESCE(SUM(t.final_fee_centavos), 0)::BIGINT  AS revenue_centavos
    FROM transactions t
   WHERE t.status = 'COMPLETED'
     AND t.start_time >= NOW() - (p_days || ' days')::INTERVAL
   GROUP BY (t.start_time AT TIME ZONE 'Asia/Manila')::DATE
   ORDER BY (t.start_time AT TIME ZONE 'Asia/Manila')::DATE DESC;
$fn$;

-- 9.3 analytics_summary — TABLE-ALIASED.
CREATE OR REPLACE FUNCTION analytics_summary(p_days INTEGER)
RETURNS TABLE (
  tx_count                BIGINT,
  revenue_centavos        BIGINT,
  cash_revenue_centavos   BIGINT,
  online_revenue_centavos BIGINT,
  avg_session_minutes     NUMERIC,
  voided_count            BIGINT,
  refunded_count          BIGINT
)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
  SELECT
    COUNT(*) FILTER (WHERE t.status = 'COMPLETED')::BIGINT,
    COALESCE(SUM(t.final_fee_centavos) FILTER (WHERE t.status = 'COMPLETED'), 0)::BIGINT,
    COALESCE(SUM(t.final_fee_centavos)
             FILTER (WHERE t.status = 'COMPLETED' AND t.payment_method = 'CASH'), 0)::BIGINT,
    COALESCE(SUM(t.final_fee_centavos)
             FILTER (WHERE t.status = 'COMPLETED' AND t.payment_method = 'ONLINE'), 0)::BIGINT,
    COALESCE(AVG(EXTRACT(EPOCH FROM (t.actual_checkout_time - t.start_time)) / 60.0)
             FILTER (WHERE t.status = 'COMPLETED'), 0)::NUMERIC,
    COUNT(*) FILTER (WHERE t.status = 'VOIDED')::BIGINT,
    COUNT(*) FILTER (WHERE t.status = 'REFUNDED')::BIGINT
    FROM transactions t
   WHERE t.start_time >= NOW() - (p_days || ' days')::INTERVAL;
$fn$;

-- 9.4 admin_daily_cash_log — TABLE-ALIASED.
CREATE OR REPLACE FUNCTION admin_daily_cash_log(p_date DATE DEFAULT NULL)
RETURNS TABLE (
  occurred_at  TIMESTAMPTZ,
  action       TEXT,
  amount_php   NUMERIC,
  actor_name   TEXT,
  actor_role   app_role,
  reason       TEXT,
  shift_id     UUID
)
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
  WITH the_date AS (
    SELECT COALESCE(p_date, (NOW() AT TIME ZONE 'Asia/Manila')::DATE) AS d
  )
  SELECT
    sca.created_at AS occurred_at,
    sca.action AS action,
    (sca.amount_centavos::NUMERIC / 100.0) AS amount_php,
    sp.display_name AS actor_name,
    sca.actor_role AS actor_role,
    sca.reason AS reason,
    sca.shift_id AS shift_id
    FROM shift_cash_audit sca
    JOIN staff_profiles sp ON sp.user_id = sca.actor_id
   WHERE (sca.created_at AT TIME ZONE 'Asia/Manila')::DATE = (SELECT d FROM the_date)
  UNION ALL
  SELECT
    cm.created_at AS occurred_at,
    'CASH_' || cm.kind || CASE WHEN cm.voided THEN '_VOIDED' ELSE '' END AS action,
    (cm.amount_centavos::NUMERIC / 100.0) AS amount_php,
    sp.display_name AS actor_name,
    cm.actor_role AS actor_role,
    cm.reason AS reason,
    cm.shift_id AS shift_id
    FROM cash_movements cm
    JOIN staff_profiles sp ON sp.user_id = cm.actor_id
   WHERE (cm.created_at AT TIME ZONE 'Asia/Manila')::DATE = (SELECT d FROM the_date)
   ORDER BY 1 DESC;
$fn$;

-- 9.5 build_receipt_payload — called by the send-receipt Edge Function.
CREATE OR REPLACE FUNCTION build_receipt_payload(p_transaction_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER STABLE
SET search_path = public AS $fn$
DECLARE
  v_payload JSONB;
BEGIN
  SELECT jsonb_build_object(
    'transaction_id',         t.transaction_id,
    'barcode',                t.barcode,
    'status',                 t.status,
    'start_time',             t.start_time,
    'end_time',               t.end_time,
    'actual_checkout_time',   t.actual_checkout_time,
    'payment_method',         t.payment_method,
    'final_fee_centavos',     t.final_fee_centavos,
    'cash_tendered_centavos', t.cash_tendered_centavos,
    'change_given_centavos',  t.change_given_centavos,
    'customer', jsonb_build_object(
      'customer_id', cp.customer_id,
      'first_name',  cp.first_name,
      'last_name',   cp.last_name,
      'email',       cp.email
    ),
    'line_items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'kind',             li.kind,
        'duration_minutes', li.duration_minutes,
        'amount_centavos',  li.amount_centavos,
        'created_at',       li.created_at
      ) ORDER BY li.created_at)
      FROM transaction_line_items li
      WHERE li.transaction_id = t.transaction_id
    ), '[]'::jsonb)
  ) INTO v_payload
  FROM transactions t
  JOIN customer_profiles cp ON cp.customer_id = t.customer_id
  WHERE t.transaction_id = p_transaction_id;

  RETURN v_payload;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 10. RECEIPT EMAIL TRIGGER
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trigger_send_receipt()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_base_url TEXT;
  v_secret   TEXT;
BEGIN
  IF NEW.status <> 'COMPLETED' OR OLD.status = 'COMPLETED' THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_base_url := current_setting('app.functions_base_url', TRUE);
    v_secret   := current_setting('app.cron_secret', TRUE);
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;

  IF v_base_url IS NULL OR v_secret IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url     := v_base_url || '/send-receipt',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_secret,
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object('transaction_id', NEW.transaction_id)
  );

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS transactions_send_receipt ON transactions;
CREATE TRIGGER transactions_send_receipt
  AFTER UPDATE OF status ON transactions
  FOR EACH ROW
  WHEN (NEW.status = 'COMPLETED' AND OLD.status <> 'COMPLETED')
  EXECUTE FUNCTION trigger_send_receipt();

-- ---------------------------------------------------------------------------
-- 11. SEED PRICING CONFIG — ₱100/hr, ₱250/5hr, 15-min grace.
-- ---------------------------------------------------------------------------
INSERT INTO pricing_config (
  effective_from, rate_1hr_centavos, rate_5hr_centavos, grace_minutes,
  auto_extension_centavos, auto_extension_minutes, max_session_minutes
)
SELECT
  NOW(), 10000, 25000, 15, 10000, 60, 900
WHERE NOT EXISTS (SELECT 1 FROM pricing_config);

-- ---------------------------------------------------------------------------
-- 12. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
ALTER TABLE staff_profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing_config         ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_logs              ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_movements         ENABLE ROW LEVEL SECURITY;
ALTER TABLE shift_cash_audit       ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_alerts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE refunds                ENABLE ROW LEVEL SECURITY;

-- Staff can read their own profile; admins can read all.
DROP POLICY IF EXISTS staff_profiles_self_read ON staff_profiles;
CREATE POLICY staff_profiles_self_read ON staff_profiles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR auth_role_at_least('admin'));

DROP POLICY IF EXISTS staff_profiles_no_direct_write ON staff_profiles;
CREATE POLICY staff_profiles_no_direct_write ON staff_profiles
  FOR ALL TO authenticated USING (FALSE) WITH CHECK (FALSE);

-- All authenticated can read customer profiles (needed for POS lookup).
DROP POLICY IF EXISTS customer_profiles_read ON customer_profiles;
CREATE POLICY customer_profiles_read ON customer_profiles
  FOR SELECT TO authenticated, anon
  USING (TRUE);

DROP POLICY IF EXISTS customer_profiles_no_direct_write ON customer_profiles;
CREATE POLICY customer_profiles_no_direct_write ON customer_profiles
  FOR ALL TO authenticated, anon USING (FALSE) WITH CHECK (FALSE);

DROP POLICY IF EXISTS pricing_read ON pricing_config;
CREATE POLICY pricing_read ON pricing_config
  FOR SELECT TO authenticated USING (TRUE);

DROP POLICY IF EXISTS shifts_read ON shifts;
CREATE POLICY shifts_read ON shifts
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS shifts_no_direct_write ON shifts;
CREATE POLICY shifts_no_direct_write ON shifts
  FOR ALL TO authenticated USING (FALSE) WITH CHECK (FALSE);

DROP POLICY IF EXISTS transactions_read ON transactions;
CREATE POLICY transactions_read ON transactions
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS transactions_direct_update_cash_tendered ON transactions;
CREATE POLICY transactions_direct_update_cash_tendered ON transactions
  FOR UPDATE TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS transactions_no_direct_insert ON transactions;
CREATE POLICY transactions_no_direct_insert ON transactions
  FOR INSERT TO authenticated WITH CHECK (FALSE);

DROP POLICY IF EXISTS transactions_no_direct_delete ON transactions;
CREATE POLICY transactions_no_direct_delete ON transactions
  FOR DELETE TO authenticated USING (FALSE);

DROP POLICY IF EXISTS line_items_read ON transaction_line_items;
CREATE POLICY line_items_read ON transaction_line_items
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS time_logs_read ON time_logs;
CREATE POLICY time_logs_read ON time_logs
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS cash_movements_read ON cash_movements;
CREATE POLICY cash_movements_read ON cash_movements
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS shift_cash_audit_read ON shift_cash_audit;
CREATE POLICY shift_cash_audit_read ON shift_cash_audit
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

DROP POLICY IF EXISTS audit_log_read ON audit_log;
CREATE POLICY audit_log_read ON audit_log
  FOR SELECT TO authenticated USING (auth_role_at_least('admin'));

DROP POLICY IF EXISTS admin_alerts_read ON admin_alerts;
CREATE POLICY admin_alerts_read ON admin_alerts
  FOR SELECT TO authenticated USING (auth_role_at_least('admin'));

DROP POLICY IF EXISTS admin_alerts_ack ON admin_alerts;
CREATE POLICY admin_alerts_ack ON admin_alerts
  FOR UPDATE TO authenticated USING (auth_role_at_least('admin'));

DROP POLICY IF EXISTS refunds_read ON refunds;
CREATE POLICY refunds_read ON refunds
  FOR SELECT TO authenticated USING (auth_role_at_least('staff'));

-- ---------------------------------------------------------------------------
-- 13. GRANTS — RPC functions are SECURITY DEFINER, callable by authenticated.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION auth_role()                                              TO authenticated;
GRANT EXECUTE ON FUNCTION auth_role_at_least(app_role)                             TO authenticated;
GRANT EXECUTE ON FUNCTION open_shift(BIGINT)                                       TO authenticated;
GRANT EXECUTE ON FUNCTION close_shift(UUID, BIGINT)                                TO authenticated;
GRANT EXECUTE ON FUNCTION start_session(UUID, line_item_kind, TEXT)                TO authenticated;
GRANT EXECUTE ON FUNCTION extend_session(UUID, INTEGER)                            TO authenticated;
GRANT EXECUTE ON FUNCTION apply_auto_extensions_if_due(UUID)                       TO authenticated;
GRANT EXECUTE ON FUNCTION checkout_session(UUID, BIGINT)                           TO authenticated;
GRANT EXECUTE ON FUNCTION void_session(UUID, TEXT)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION register_cash_movement(TEXT, BIGINT, TEXT)               TO authenticated;
GRANT EXECUTE ON FUNCTION void_cash_movement(UUID, TEXT)                           TO authenticated;
GRANT EXECUTE ON FUNCTION admin_void_opening_cash(UUID, TEXT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION admin_void_closing_cash(UUID, TEXT)                      TO authenticated;
GRANT EXECUTE ON FUNCTION register_customer(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION find_customer_by_email(TEXT)                             TO authenticated;
GRANT EXECUTE ON FUNCTION preview_shift_cash_expected(UUID)                        TO authenticated;
GRANT EXECUTE ON FUNCTION analytics_revenue_rollup(INTEGER)                        TO authenticated;
GRANT EXECUTE ON FUNCTION analytics_summary(INTEGER)                               TO authenticated;
GRANT EXECUTE ON FUNCTION admin_daily_cash_log(DATE)                               TO authenticated;
GRANT EXECUTE ON FUNCTION build_receipt_payload(UUID)                              TO authenticated;
GRANT EXECUTE ON FUNCTION generate_barcode()                                       TO authenticated;
GRANT EXECUTE ON FUNCTION billing_current_pricing()                                TO authenticated;
GRANT EXECUTE ON FUNCTION watchdog_run_sweep()                                     TO authenticated;
GRANT EXECUTE ON FUNCTION watchdog_find_zombie_sessions(INTEGER)                   TO authenticated;
GRANT EXECUTE ON FUNCTION watchdog_force_checkout_at_cap(UUID)                     TO authenticated;
GRANT EXECUTE ON FUNCTION watchdog_verify_shift_cash(UUID)                         TO authenticated;

-- ---------------------------------------------------------------------------
-- 14. PII PURGE CRON (48 hours post-checkout, occupation/school RETAINED).
-- ---------------------------------------------------------------------------
DO $cron_setup$
BEGIN
  -- Unschedule if exists; ignore error if not.
  PERFORM cron.unschedule('pii-purge')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pii-purge');
EXCEPTION WHEN OTHERS THEN NULL;
END
$cron_setup$;

SELECT cron.schedule(
  'pii-purge',
  '0 * * * *',
  $cron_body$
    UPDATE customer_profiles
       SET first_name    = NULL,
           last_name     = NULL,
           email         = NULL,
           phone         = NULL,
           pii_purged_at = NOW()
     WHERE pii_purged_at IS NULL
       AND EXISTS (
         SELECT 1 FROM transactions t
          WHERE t.customer_id = customer_profiles.customer_id
            AND t.status = 'COMPLETED'
            AND t.actual_checkout_time < NOW() - INTERVAL '48 hours'
       )
       AND NOT EXISTS (
         SELECT 1 FROM transactions t
          WHERE t.customer_id = customer_profiles.customer_id
            AND t.status = 'ACTIVE'
       );
  $cron_body$
);

-- ---------------------------------------------------------------------------
-- 15. SMOKE TEST — actually exercises every read-only function so we
--     catch column-binding errors at migration time, not call time.
--     Mutator functions can't be exercised here (require auth.uid()), but
--     their bodies are parsed at CREATE OR REPLACE time.
-- ---------------------------------------------------------------------------
DO $smoke_test$
DECLARE
  v_passes INTEGER := 0;
  v_fails  TEXT[]  := ARRAY[]::TEXT[];
  v_tmp    JSONB;
  v_count  INTEGER;
  v_dummy  UUID := '00000000-0000-0000-0000-000000000000'::UUID;
BEGIN
  -- Test 1: every table exists.
  FOR v_tmp IN
    SELECT to_jsonb(t.table_name) FROM unnest(ARRAY[
      'staff_profiles', 'customer_profiles', 'pricing_config', 'shifts',
      'transactions', 'transaction_line_items', 'time_logs',
      'cash_movements', 'shift_cash_audit', 'audit_log',
      'admin_alerts', 'refunds'
    ]) AS t(table_name)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.tables
       WHERE table_schema = 'public' AND table_name = v_tmp #>> '{}'
    ) THEN
      v_fails := array_append(v_fails, 'TABLE missing: ' || (v_tmp #>> '{}'));
    ELSE
      v_passes := v_passes + 1;
    END IF;
  END LOOP;

  -- Test 2: pricing_config seeded.
  SELECT COUNT(*) INTO v_count FROM pricing_config;
  IF v_count >= 1 THEN
    v_passes := v_passes + 1;
  ELSE
    v_fails := array_append(v_fails, 'pricing_config not seeded');
  END IF;

  -- Test 3: billing_current_pricing returns a row.
  BEGIN
    PERFORM billing_current_pricing();
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'billing_current_pricing: ' || SQLERRM);
  END;

  -- Test 4: find_customer_by_email — exercises the TABLE-aliased query.
  BEGIN
    PERFORM * FROM find_customer_by_email('nonexistent@example.com');
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'find_customer_by_email: ' || SQLERRM);
  END;

  -- Test 5: analytics_revenue_rollup — the one that bit us last time.
  BEGIN
    PERFORM * FROM analytics_revenue_rollup(30);
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'analytics_revenue_rollup: ' || SQLERRM);
  END;

  -- Test 6: analytics_summary.
  BEGIN
    PERFORM * FROM analytics_summary(30);
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'analytics_summary: ' || SQLERRM);
  END;

  -- Test 7: admin_daily_cash_log — also TABLE-RETURNS with aliases.
  BEGIN
    PERFORM * FROM admin_daily_cash_log(CURRENT_DATE);
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'admin_daily_cash_log: ' || SQLERRM);
  END;

  -- Test 8: build_receipt_payload — exercises the JSONB query.
  BEGIN
    PERFORM build_receipt_payload(v_dummy);
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'build_receipt_payload: ' || SQLERRM);
  END;

  -- Test 9: watchdog_find_zombie_sessions.
  BEGIN
    PERFORM * FROM watchdog_find_zombie_sessions(15);
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'watchdog_find_zombie_sessions: ' || SQLERRM);
  END;

  -- Test 10: generate_barcode.
  BEGIN
    PERFORM generate_barcode();
    v_passes := v_passes + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fails := array_append(v_fails, 'generate_barcode: ' || SQLERRM);
  END;

  -- Report.
  IF array_length(v_fails, 1) IS NULL THEN
    RAISE NOTICE '----------------------------------------------------------';
    RAISE NOTICE 'UBBS V2 MIGRATION: ALL % SMOKE TESTS PASSED', v_passes;
    RAISE NOTICE '----------------------------------------------------------';
    RAISE NOTICE 'Next steps:';
    RAISE NOTICE '  1. Set app.functions_base_url + app.cron_secret';
    RAISE NOTICE '  2. Deploy the send-receipt Edge Function';
    RAISE NOTICE '  3. Create your first admin auth user + staff_profiles row';
    RAISE NOTICE '  4. Run: streamlit run app.py';
  ELSE
    RAISE WARNING '----------------------------------------------------------';
    RAISE WARNING 'UBBS V2 MIGRATION: % PASSED, % FAILED', v_passes, array_length(v_fails, 1);
    RAISE WARNING 'Failures:';
    FOR v_count IN 1 .. array_length(v_fails, 1) LOOP
      RAISE WARNING '  %', v_fails[v_count];
    END LOOP;
    RAISE WARNING '----------------------------------------------------------';
  END IF;
END
$smoke_test$;
