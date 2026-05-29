"""UBBS — Usage-Based Billing System (V2 single-file Streamlit app).

This is a SINGLE-FILE Streamlit application that replaces the V1 multi-page
layout. Internal routing (no sidebar pages) drives the four funnels:
  - Customer Registration  (public, no auth required)
  - Staff Dashboard        (staff+)
  - Manager Dashboard      (manager+, adds void capability)
  - Admin Dashboard        (admin, adds analytics + cash overrides + audit)

Run locally:
    streamlit run app.py --server.port 8501

Routing convention:
    ?page=register                                 customer registration
    everything else                                login → role-gated dashboard
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import pathlib
import time
from datetime import date, datetime, timedelta, timezone
from typing import Any

import pandas as pd
import streamlit as st
from supabase import Client, create_client

# =============================================================================
# SECTION 1 — CONSTANTS & CONFIGURATION
# =============================================================================

PHT = timezone(timedelta(hours=8))
UTC = timezone.utc
APP_VERSION = "v2.0.0"

# Pricing — must match pricing_config seed row in migrations/0001_init.sql.
PRICE_1HR_CENTAVOS = 10_000
PRICE_5HR_CENTAVOS = 25_000
PRICE_AUTO_EXT_CENTAVOS = 10_000
DURATION_1HR_MINUTES = 60
DURATION_5HR_MINUTES = 300
DURATION_AUTO_EXT_MINUTES = 60
GRACE_MINUTES = 15
MAX_SESSION_MINUTES = 900

# Polling interval for cross-funnel sync.
POLL_SECONDS = 2

# Session cookie name (used as the key in the server-side session file store).
COOKIE_AUTH_NAME = "ubbs_auth"

OCCUPATIONS = ["Student", "Employed", "Self-Employed", "Freelancer", "Unemployed", "Retired", "Other"]


# =============================================================================
# SECTION 2 — STREAMLIT PAGE CONFIG (must be first Streamlit call)
# =============================================================================

st.set_page_config(
    page_title="UBBS — Venue Billing",
    page_icon="🎮",
    layout="wide",
    initial_sidebar_state="collapsed",
    menu_items={"About": f"UBBS {APP_VERSION}"},
)


# =============================================================================
# SECTION 3 — SIDEBAR REMOVAL (V2 item 11 / Sec 1.2)
# Streamlit auto-generates a sidebar nav from pages/*.py. We hide it entirely.
# =============================================================================

def hide_streamlit_chrome() -> None:
    """Hide the sidebar, the page nav, the header menu, and the footer."""
    st.markdown(
        """
        <style>
          [data-testid="stSidebar"], [data-testid="stSidebarNav"],
          [data-testid="stSidebarCollapsedControl"] { display: none !important; }
          header [data-testid="stMainMenu"] { display: none !important; }
          footer { visibility: hidden; }
          .block-container { padding-top: 1.5rem; }
          /* Highlight states for active session rows */
          .ubbs-row-yellow td { background-color: #fff3cd !important; }
          .ubbs-row-red    td { background-color: #f8d7da !important; }
        </style>
        """,
        unsafe_allow_html=True,
    )


# =============================================================================
# SECTION 4 — SUPABASE CLIENT FACTORIES
# =============================================================================

def _env(name: str, default: str | None = None) -> str:
    """Resolve env var or Streamlit secrets entry. Streamlit Cloud puts these
    in `st.secrets`; local dev can use either env or .streamlit/secrets.toml."""
    val = os.environ.get(name)
    if val:
        return val
    try:
        sec = st.secrets[name]
        if sec:
            return str(sec)
    except (KeyError, FileNotFoundError, st.errors.StreamlitSecretNotFoundError):
        pass
    if default is None:
        st.error(f"Missing required configuration: {name}")
        st.stop()
    return default


@st.cache_resource
def anon_client() -> Client:
    """Anonymous (RLS-restricted) Supabase client. Used for the registration form."""
    return create_client(_env("SUPABASE_URL"), _env("SUPABASE_ANON_KEY"))


def authed_client(access_token: str, refresh_token: str) -> Client:
    """Authenticated Supabase client bound to a specific user session."""
    cli = create_client(_env("SUPABASE_URL"), _env("SUPABASE_ANON_KEY"))
    cli.auth.set_session(access_token, refresh_token)
    return cli


# =============================================================================
# SECTION 5 — COOKIE-BACKED SESSION PERSISTENCE (V2 item 1 / Sec 1.1)
# Browser refresh must not kick the user back to login.
# =============================================================================

# =============================================================================
# SECTION 5b — SERVER-SIDE SESSION STORE
# Tokens are written to a local .sessions/ folder on login. The session ID
# (a 32-char hex hash) is kept in the URL (?sid=...) which survives F5
# refreshes because the browser keeps the current URL on reload.
# No browser cookies or JS components needed.
# =============================================================================

_SESSION_DIR = pathlib.Path(__file__).parent / ".sessions"


def _session_file(sid: str) -> pathlib.Path:
    return _SESSION_DIR / f"{sid}.json"


def store_session(access_token: str, refresh_token: str) -> None:
    _SESSION_DIR.mkdir(exist_ok=True)
    sid = hashlib.sha256(access_token.encode()).hexdigest()[:32]
    _session_file(sid).write_text(
        json.dumps({"access": access_token, "refresh": refresh_token})
    )
    st.query_params["sid"] = sid


def clear_session() -> None:
    sid = st.query_params.get("sid")
    if sid:
        try:
            _session_file(sid).unlink(missing_ok=True)
        except Exception:
            pass
    try:
        st.query_params.clear()
    except Exception:
        pass
    for k in list(st.session_state.keys()):
        del st.session_state[k]


def restore_session() -> bool:
    """Read session ID from URL, load tokens from disk, hydrate session_state."""
    if st.session_state.get("user") and st.session_state.get("supabase"):
        return True

    sid = st.query_params.get("sid")
    if not sid:
        return False

    sf = _session_file(sid)
    if not sf.exists():
        return False

    try:
        tokens = json.loads(sf.read_text())
    except Exception:
        return False

    try:
        cli = authed_client(tokens["access"], tokens["refresh"])
        user_resp = cli.auth.get_user()
        if not user_resp or not user_resp.user:
            sf.unlink(missing_ok=True)
            return False
        profile = (
            cli.table("staff_profiles")
            .select("user_id, display_name, role")
            .eq("user_id", user_resp.user.id)
            .single()
            .execute()
        )
        st.session_state.supabase = cli
        st.session_state.user = {
            "user_id": user_resp.user.id,
            "email": user_resp.user.email,
            "display_name": profile.data["display_name"],
            "role": profile.data["role"],
        }
        return True
    except Exception:
        clear_session()
        return False


# =============================================================================
# SECTION 5b — NOTIFICATION SYSTEM
# Messages are stored in session_state so they survive st.rerun() calls.
# Call _notify() in action handlers; call _show_notify() at the top of each
# dashboard render so the message appears after the rerun.
# =============================================================================

def _notify(msg: str, level: str = "success") -> None:
    """Queue a notification to be shown after the next rerun."""
    st.session_state["_pending_notify"] = {"msg": msg, "level": level}


def _show_notify() -> None:
    """Render and clear any queued notification."""
    n = st.session_state.pop("_pending_notify", None)
    if not n:
        return
    level = n.get("level", "success")
    if level == "success":
        st.success(n["msg"])
    elif level == "warning":
        st.warning(n["msg"])
    elif level == "error":
        st.error(n["msg"])
    else:
        st.info(n["msg"])


# =============================================================================
# SECTION 6 — BILLING PROJECTION (mirror of Postgres billing_calc_session_state)
# =============================================================================

def project_session_state(
    *,
    start_time: datetime,
    contracted_end: datetime,
    current_end: datetime,
    line_items: list[dict[str, Any]],
    status: str,
    now: datetime,
) -> dict[str, Any]:
    """Compute the live state of an active or terminal session.

    Returns a dict with: minutes_past, in_grace, applied_auto, expected_auto,
    pending_auto, line_total_centavos, projected_total_centavos, highlight,
    next_charge_at.
    """
    line_total = sum(int(li["amount_centavos"]) for li in line_items)
    applied_auto = sum(1 for li in line_items if li["kind"] == "EXTENSION_AUTO_GRACE")

    if status in ("COMPLETED", "VOIDED", "REFUNDED"):
        return {
            "minutes_past": 0,
            "in_grace": False,
            "applied_auto": applied_auto,
            "expected_auto": applied_auto,
            "pending_auto": 0,
            "line_total_centavos": line_total,
            "projected_total_centavos": line_total,
            "highlight": "none",
            "next_charge_at": None,
            "is_terminal": True,
        }

    delta_seconds = (now - contracted_end).total_seconds()
    minutes_past = max(0, math.ceil(delta_seconds / 60.0)) if delta_seconds > 0 else 0
    in_grace = minutes_past <= GRACE_MINUTES

    if in_grace:
        expected_auto = 0
    else:
        expected_auto = max(1, math.ceil(minutes_past / DURATION_AUTO_EXT_MINUTES))

    pending_auto = max(0, expected_auto - applied_auto)
    projected_total = line_total + pending_auto * PRICE_AUTO_EXT_CENTAVOS

    if minutes_past == 0:
        highlight = "none"
    elif in_grace:
        highlight = "yellow"
    else:
        highlight = "red"

    if in_grace:
        next_charge = contracted_end + timedelta(minutes=GRACE_MINUTES + 1)
    else:
        next_charge = contracted_end + timedelta(minutes=expected_auto * DURATION_AUTO_EXT_MINUTES + 1)
        cap = start_time + timedelta(minutes=MAX_SESSION_MINUTES)
        if next_charge > cap:
            next_charge = None

    return {
        "minutes_past": minutes_past,
        "in_grace": in_grace,
        "applied_auto": applied_auto,
        "expected_auto": expected_auto,
        "pending_auto": pending_auto,
        "line_total_centavos": line_total,
        "projected_total_centavos": projected_total,
        "highlight": highlight,
        "next_charge_at": next_charge,
        "is_terminal": False,
    }


# =============================================================================
# SECTION 7 — FORMATTING HELPERS (V2 item 21 — clean column headers)
# =============================================================================

def fmt_centavos(c: int | None) -> str:
    if c is None:
        return "—"
    sign = "-" if c < 0 else ""
    abs_c = abs(int(c))
    return f"{sign}₱{abs_c // 100:,}.{abs_c % 100:02d}"


def fmt_pht(dt: datetime | str | None) -> str:
    if dt is None:
        return "—"
    if isinstance(dt, str):
        try:
            dt = datetime.fromisoformat(dt.replace("Z", "+00:00"))
        except ValueError:
            return dt
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(PHT).strftime("%Y-%m-%d %I:%M %p")


def fmt_duration(minutes: int) -> str:
    h, m = divmod(int(minutes), 60)
    if h and m:
        return f"{h}h {m}m"
    if h:
        return f"{h}h"
    return f"{m}m"


def humanize_column(col: str) -> str:
    """Convert snake_case → Title Case, strip _id/_at/_centavos suffixes nicely."""
    overrides = {
        "tx_count": "Transactions",
        "tx_id": "Transaction ID",
        "shift_id": "Shift ID",
        "movement_id": "Movement ID",
        "user_id": "User ID",
        "customer_id": "Customer ID",
        "amount_php": "Amount (₱)",
        "amount_centavos": "Amount",
    }
    if col in overrides:
        return overrides[col]
    if col.endswith("_centavos"):
        return humanize_column(col[: -len("_centavos")]) + " (₱)"
    return col.replace("_", " ").title()


def humanize_columns(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return df
    return df.rename(columns={c: humanize_column(c) for c in df.columns})


def now_utc() -> datetime:
    return datetime.now(tz=UTC)


# =============================================================================
# SECTION 8 — SAFE RPC WRAPPER (Hard Invariant H4)
# =============================================================================

def call_rpc(client: Client, name: str, params: dict[str, Any] | None = None) -> Any:
    """Wrap supabase.rpc with consistent error display."""
    try:
        return client.rpc(name, params or {}).execute().data
    except Exception as e:
        msg = str(e)
        # Strip the verbose postgrest envelope for readability.
        if "message" in msg and "hint" in msg:
            try:
                detail = json.loads(msg.split("Postgrest")[-1].strip().lstrip(":").strip())
                msg = detail.get("message", msg)
            except Exception:
                pass
        st.error(f"❌ {name}: {msg}")
        return None


# =============================================================================
# SECTION 9 — AUTH (login, logout, role-gate)
# =============================================================================

def do_login(email: str, password: str) -> bool:
    try:
        cli = create_client(_env("SUPABASE_URL"), _env("SUPABASE_ANON_KEY"))
        resp = cli.auth.sign_in_with_password({"email": email, "password": password})
        if not resp.user or not resp.session:
            st.error("Invalid credentials.")
            return False

        profile = (
            cli.table("staff_profiles")
            .select("user_id, display_name, role")
            .eq("user_id", resp.user.id)
            .maybe_single()
            .execute()
        )
        if not profile or not profile.data:
            st.error("No staff profile found for this account. Contact an admin.")
            return False

        st.session_state.supabase = cli
        st.session_state.user = {
            "user_id": resp.user.id,
            "email": resp.user.email,
            "display_name": profile.data["display_name"],
            "role": profile.data["role"],
        }
        store_session(resp.session.access_token, resp.session.refresh_token)
        return True
    except Exception as e:
        st.error(f"Login failed: {e}")
        return False


def do_logout() -> None:
    try:
        if "supabase" in st.session_state:
            st.session_state.supabase.auth.sign_out()
    except Exception:
        pass
    clear_session()
    st.rerun()


def require_role(min_role: str) -> bool:
    user = st.session_state.get("user")
    if not user:
        return False
    rank = {"staff": 0, "manager": 1, "admin": 2}
    return rank.get(user["role"], -1) >= rank.get(min_role, 99)


# =============================================================================
# SECTION 10 — SHIFT GATE (V2 item 7 / Sec 3.1 — mandatory cash counts)
# =============================================================================

def get_open_shift(client: Client) -> dict | None:
    try:
        res = (
            client.table("shifts")
            .select("*")
            .eq("status", "OPEN")
            .maybe_single()
            .execute()
        )
        return res.data if res else None
    except Exception:
        return None


def shift_gate(client: Client) -> dict | None:
    """Block dashboard access until an OPEN shift exists with opening_cash set.
    Admins bypass the gate entirely — shift management is optional for them.
    Returns the open shift dict (or empty dict for admin with no open shift),
    or None if a non-admin user is still at the cash entry screen."""
    shift = get_open_shift(client)
    is_admin = st.session_state.get("user", {}).get("role") == "admin"

    # Admin bypass: skip the gate entirely, return shift (or empty dict if none).
    if is_admin:
        return shift or {}

    # Non-admin: must have an open shift with opening cash recorded.
    if shift and shift.get("opening_cash_centavos") is not None:
        return shift

    st.title("💰 Open Shift")
    if shift and shift.get("opening_cash_centavos") is None:
        st.warning(
            "An admin voided the opening cash count for this shift. "
            "Re-enter the opening cash to continue."
        )
        if shift.get("opening_void_reason"):
            st.caption(f"Void reason: {shift['opening_void_reason']}")
    else:
        st.info(
            "No shift is open. Count the cash drawer and record the opening "
            "amount to start the day."
        )

    amount = st.number_input(
        "Opening Cash in Register (₱)",
        min_value=0.00, step=1.00, format="%.2f", key="open_shift_amount",
    )
    if st.button("💾 Record Opening Amount & Continue", type="primary"):
        centavos = int(round(amount * 100))
        result = call_rpc(client, "open_shift", {"p_opening_cash_centavos": centavos})
        if result:
            _notify("Shift opened. Loading dashboard…")
            st.rerun()
    return None


# =============================================================================
# SECTION 11 — DATA FETCHERS (used across funnels, with light caching)
# =============================================================================

def fetch_active_sessions(client: Client) -> list[dict]:
    try:
        txs = (
            client.table("transactions")
            .select(
                "transaction_id, barcode, start_time, end_time, status, "
                "payment_method, customer_id, shift_id, created_by, cash_tendered_centavos"
            )
            .eq("status", "ACTIVE")
            .order("start_time")
            .execute()
            .data or []
        )
    except Exception as e:
        st.error(f"Failed to fetch active sessions: {e}")
        return []

    if not txs:
        return []

    customer_ids = list({t["customer_id"] for t in txs if t.get("customer_id")})
    customers = {}
    if customer_ids:
        cust_data = (
            client.table("customer_profiles")
            .select("customer_id, first_name, last_name, email")
            .in_("customer_id", customer_ids)
            .execute()
            .data or []
        )
        customers = {c["customer_id"]: c for c in cust_data}

    tx_ids = [t["transaction_id"] for t in txs]
    line_items_by_tx: dict[str, list] = {tid: [] for tid in tx_ids}
    if tx_ids:
        items = (
            client.table("transaction_line_items")
            .select("transaction_id, kind, duration_minutes, amount_centavos, created_at")
            .in_("transaction_id", tx_ids)
            .execute()
            .data or []
        )
        for it in items:
            line_items_by_tx.setdefault(it["transaction_id"], []).append(it)

    enriched = []
    now = now_utc()
    for tx in txs:
        cust = customers.get(tx["customer_id"], {})
        items = line_items_by_tx.get(tx["transaction_id"], [])
        start_dt = datetime.fromisoformat(tx["start_time"].replace("Z", "+00:00"))
        end_dt = datetime.fromisoformat(tx["end_time"].replace("Z", "+00:00"))
        auto_count = sum(1 for li in items if li["kind"] == "EXTENSION_AUTO_GRACE")
        contracted_end = end_dt - timedelta(minutes=auto_count * DURATION_AUTO_EXT_MINUTES)

        state = project_session_state(
            start_time=start_dt,
            contracted_end=contracted_end,
            current_end=end_dt,
            line_items=items,
            status=tx["status"],
            now=now,
        )
        enriched.append({
            **tx,
            "customer_name": (
                f"{cust.get('first_name','')} {cust.get('last_name','')}".strip() or "—"
            ),
            "customer_email": cust.get("email"),
            "contracted_end": contracted_end,
            "current_end": end_dt,
            "line_items": items,
            "state": state,
        })
    return enriched


# =============================================================================
# SECTION 12 — PUBLIC CUSTOMER REGISTRATION (V2 item 2 / Sec 2.1)
# =============================================================================

def page_customer_registration() -> None:
    hide_streamlit_chrome()
    st.title("📝 Customer Registration")
    st.caption("Register once. Staff can pull your details up by email on every visit.")

    with st.form("customer_reg", clear_on_submit=False):
        c1, c2 = st.columns(2)
        first_name = c1.text_input("First Name *")
        last_name = c2.text_input("Last Name *")

        email = st.text_input("Email *", help="Your receipts will be sent here.")
        phone = st.text_input("Phone (optional)")

        occupation = st.selectbox("Occupation *", options=[""] + OCCUPATIONS, index=0)
        school = ""
        if occupation == "Student":
            school = st.text_input("School *", help="Required because you selected Student.")

        submitted = st.form_submit_button("✅ Submit Registration", type="primary")

        if submitted:
            if not first_name.strip() or not last_name.strip():
                st.error("First name and last name are required.")
                return
            if not email.strip() or "@" not in email:
                st.error("A valid email is required.")
                return
            if not occupation:
                st.error("Please select an occupation.")
                return
            if occupation == "Student" and not school.strip():
                st.error("School is required when occupation is Student.")
                return

            try:
                result = anon_client().rpc("register_customer", {
                    "p_first_name": first_name,
                    "p_last_name":  last_name,
                    "p_email":      email,
                    "p_phone":      phone or None,
                    "p_occupation": occupation,
                    "p_school":     school or None,
                }).execute()
                if result.data:
                    st.success(f"Registered! Show this email to staff to begin: **{email.strip().lower()}**")
                    st.balloons()
            except Exception as e:
                st.error(f"Registration failed: {e}")


# =============================================================================
# SECTION 13 — LOGIN PAGE
# =============================================================================

def page_login() -> None:
    hide_streamlit_chrome()
    st.title("🎮 UBBS")
    st.caption("Venue Billing System — Staff Sign-In")

    col_a, col_b = st.columns([3, 2])
    with col_a:
        with st.form("login"):
            email = st.text_input("Email")
            password = st.text_input("Password", type="password")
            submitted = st.form_submit_button("Sign In", type="primary")
            if submitted:
                if do_login(email, password):
                    st.rerun()

    with col_b:
        st.info(
            "**Customer?** Use the registration page instead:  \n"
            "`?page=register` in the URL."
        )


# =============================================================================
# SECTION 14 — STAFF DASHBOARD COMPONENTS
# =============================================================================

def staff_tab_new_order(client: Client) -> None:
    """V2 items 12, 13 — customer lookup + cash change calculator."""
    st.subheader("🧾 New Order")

    if "new_order_customer" not in st.session_state:
        st.session_state.new_order_customer = None
    if "new_order_tx_id" not in st.session_state:
        st.session_state.new_order_tx_id = None
    if "new_order_total_centavos" not in st.session_state:
        st.session_state.new_order_total_centavos = 0
    if "new_order_payment_method" not in st.session_state:
        st.session_state.new_order_payment_method = None

    # Step 1: Customer lookup.
    st.markdown("**Step 1 — Identify the customer**")
    email = st.text_input("Customer Email", key="lookup_email")
    c1, c2 = st.columns([1, 3])
    with c1:
        if st.button("🔍 Look up"):
            if not email.strip():
                st.warning("Enter an email to search.")
            else:
                data = call_rpc(client, "find_customer_by_email", {"p_email": email})
                if data:
                    st.session_state.new_order_customer = data[0] if isinstance(data, list) else data
                else:
                    st.session_state.new_order_customer = None
                    st.warning("No customer found with that email. Have them register first.")
    with c2:
        cust = st.session_state.new_order_customer
        if cust:
            st.success(
                f"✓ {cust.get('first_name','')} {cust.get('last_name','')}  ·  "
                f"{cust.get('occupation') or '—'}"
                + (f"  ·  {cust.get('school')}" if cust.get("school") else "")
            )

    if not st.session_state.new_order_customer:
        return

    st.divider()

    # Step 2: Pick order + payment.
    st.markdown("**Step 2 — Order details**")
    c1, c2 = st.columns(2)
    with c1:
        order_kind = st.radio(
            "Order",
            options=["INITIAL_1HR", "INITIAL_5HR"],
            format_func=lambda k: "1 Hour — ₱100.00" if k == "INITIAL_1HR" else "5 Hours — ₱250.00",
            key="new_order_kind",
        )
    with c2:
        payment_method = st.radio(
            "Payment Method",
            options=["CASH", "ONLINE"],
            key="new_order_payment_method_radio",
        )

    order_total = PRICE_1HR_CENTAVOS if order_kind == "INITIAL_1HR" else PRICE_5HR_CENTAVOS
    st.markdown(f"**Order Total:** {fmt_centavos(order_total)}")

    st.divider()

    # Step 3: Cash change calculator OR confirm online.
    st.markdown("**Step 3 — Confirm payment**")
    if payment_method == "CASH":
        tendered_php = st.number_input(
            "Customer's Cash Payment (₱)",
            min_value=0.00, step=10.00, format="%.2f",
            key="cash_tendered_input",
        )
        tendered_centavos = int(round(tendered_php * 100))
        change_centavos = tendered_centavos - order_total

        col_a, col_b = st.columns(2)
        col_a.metric("Amount Due", fmt_centavos(order_total))
        col_b.metric(
            "Change Due",
            fmt_centavos(change_centavos) if change_centavos >= 0 else "INSUFFICIENT",
            delta=None if change_centavos >= 0 else "Need more cash",
            delta_color="inverse" if change_centavos < 0 else "normal",
        )

        if st.button("✅ Confirm Order & Start Timer", type="primary", disabled=(change_centavos < 0)):
            _create_session(client, order_kind, "CASH", tendered_centavos)
    else:
        if st.button("✅ Confirm Order & Start Timer", type="primary"):
            _create_session(client, order_kind, "ONLINE", None)


def _create_session(client: Client, kind: str, payment_method: str, tendered_centavos: int | None) -> None:
    cust = st.session_state.new_order_customer
    tx_id = call_rpc(
        client,
        "start_session",
        {
            "p_customer_id": cust["customer_id"],
            "p_initial_kind": kind,
            "p_payment_method": payment_method,
        },
    )
    if not tx_id:
        return

    # Persist tendered immediately on the row so it's not lost if checkout
    # happens later. (Final fee & change are only set at checkout_session time.)
    if tendered_centavos is not None:
        try:
            client.table("transactions").update({
                "cash_tendered_centavos": tendered_centavos,
            }).eq("transaction_id", tx_id).execute()
        except Exception as e:
            _notify(f"Saved order but failed to record tendered amount: {e}", "warning")

    if "_pending_notify" not in st.session_state:
        _notify(
            f"Session started for {cust.get('first_name','')} {cust.get('last_name','')} "
            f"(barcode visible in Active Sessions)."
        )
    # Reset wizard.
    st.session_state.new_order_customer = None
    st.session_state.new_order_tx_id = None
    st.rerun()


def _render_extend_cash_flow(client: Client, tx: dict, ext_kind: str) -> None:
    """Cash collection confirmation before an in-window extension."""
    tx_id = tx["transaction_id"]
    state_key = f"extending_{tx_id}_{ext_kind}"
    price = PRICE_1HR_CENTAVOS if ext_kind == "INITIAL_1HR" else PRICE_5HR_CENTAVOS
    label = "1 Hour" if ext_kind == "INITIAL_1HR" else "5 Hours"

    with st.container(border=True):
        st.markdown(f"### Extend {label} — {tx['customer_name']}")
        st.markdown(f"**Extension fee:** {fmt_centavos(price)}")

        tendered_php = st.number_input(
            "Cash Tendered (₱)",
            min_value=0.00, step=10.00, format="%.2f",
            key=f"extend_cash_{tx_id}_{ext_kind}",
            value=float(price) / 100.0,
        )
        tendered_centavos = int(round(tendered_php * 100))
        change = tendered_centavos - price
        col_a, col_b = st.columns(2)
        col_a.metric("Fee", fmt_centavos(price))
        col_b.metric("Change", fmt_centavos(change) if change >= 0 else "INSUFFICIENT")

        c1, c2 = st.columns([1, 4])
        with c1:
            if st.button("✓ Confirm & Extend", key=f"confirm_extend_{tx_id}_{ext_kind}",
                         type="primary", disabled=(change < 0)):
                st.session_state.pop(state_key, None)
                _extend_or_new(client, tx, ext_kind)
        with c2:
            if st.button("✗ Cancel", key=f"cancel_extend_{tx_id}_{ext_kind}"):
                st.session_state.pop(state_key, None)
                st.rerun()


def render_active_sessions_table(sessions: list[dict], show_actions: bool, client: Client) -> None:
    """V2 items 17, 18 — render with grace period countdown + color states."""
    if not sessions:
        st.info("No active sessions right now.")
        return

    for tx in sessions:
        state = tx["state"]
        highlight = state["highlight"]
        border_color = {"yellow": "#ffc107", "red": "#dc3545", "none": "#444"}[highlight]
        bg_color = {"yellow": "#fff3cd", "red": "#f8d7da", "none": "transparent"}[highlight]
        text_color = "#000" if highlight in ("yellow", "red") else "inherit"

        minutes_past = state["minutes_past"]
        if state["is_terminal"]:
            time_label = "ENDED"
        elif minutes_past == 0:
            time_label = "⏱ Within scheduled time"
        elif state["in_grace"]:
            remaining = GRACE_MINUTES - minutes_past
            time_label = f"⚠ GRACE — {remaining} min left in grace"
        else:
            time_label = f"🔴 OVERLIMIT — {minutes_past} min past end"

        with st.container(border=False):
            st.markdown(
                f"""
                <div style='border:2px solid {border_color};background:{bg_color};
                            color:{text_color};border-radius:8px;padding:14px;margin:8px 0;'>
                  <div style='display:flex;justify-content:space-between;align-items:flex-start;'>
                    <div>
                      <strong style='font-size:16px;'>{tx['customer_name']}</strong>
                      <span style='color:#666;'>·</span>
                      <code style='color:#444;'>{tx['barcode']}</code>
                    </div>
                    <div style='font-weight:bold;'>{time_label}</div>
                  </div>
                  <div style='margin-top:8px;font-size:14px;'>
                    Start: <strong>{fmt_pht(tx['start_time'])}</strong> ·
                    End: <strong>{fmt_pht(tx['current_end'])}</strong> ·
                    Payment: <strong>{tx['payment_method']}</strong>
                  </div>
                  <div style='margin-top:6px;font-size:14px;'>
                    Current Total: <strong>{fmt_centavos(state['projected_total_centavos'])}</strong>
                    (line items: {fmt_centavos(state['line_total_centavos'])},
                     auto-extensions pending: {state['pending_auto']})
                  </div>
                </div>
                """,
                unsafe_allow_html=True,
            )

            if show_actions:
                action_cols = st.columns([1, 1, 1, 1])
                tx_id = tx["transaction_id"]

                with action_cols[0]:
                    if st.button("➕ Extend (+1hr)", key=f"ext_{tx_id}"):
                        if tx["payment_method"] == "CASH":
                            st.session_state[f"extending_{tx_id}_INITIAL_1HR"] = True
                        else:
                            _extend_or_new(client, tx, "INITIAL_1HR")

                with action_cols[1]:
                    if st.button("➕ Extend (+5hr)", key=f"ext5_{tx_id}"):
                        if tx["payment_method"] == "CASH":
                            st.session_state[f"extending_{tx_id}_INITIAL_5HR"] = True
                        else:
                            _extend_or_new(client, tx, "INITIAL_5HR")

                with action_cols[2]:
                    if st.button("✅ Close Order", key=f"close_{tx_id}", type="primary"):
                        st.session_state[f"closing_{tx_id}"] = True

                with action_cols[3]:
                    if require_role("manager"):
                        if st.button("❌ Void", key=f"void_{tx_id}"):
                            st.session_state[f"voiding_{tx_id}"] = True

                # Inline extend cash flows.
                if st.session_state.get(f"extending_{tx_id}_INITIAL_1HR"):
                    _render_extend_cash_flow(client, tx, "INITIAL_1HR")
                if st.session_state.get(f"extending_{tx_id}_INITIAL_5HR"):
                    _render_extend_cash_flow(client, tx, "INITIAL_5HR")

                # Inline close flow.
                if st.session_state.get(f"closing_{tx_id}"):
                    _render_close_flow(client, tx)

                # Inline void flow.
                if st.session_state.get(f"voiding_{tx_id}"):
                    _render_void_flow(client, tx)


def _extend_or_new(client: Client, tx: dict, ext_kind: str) -> None:
    """V2 items 16, 10, 20 — extension cutover rule.

    Rule: if now < contracted_end → extend the same tx (same grace window).
          if now >= contracted_end → close old tx, open new tx for the extension.
    """
    now = now_utc()
    contracted_end = tx["contracted_end"]

    if now < contracted_end:
        # In-window extension: same tx, push back end_time.
        duration = DURATION_1HR_MINUTES if ext_kind == "INITIAL_1HR" else DURATION_5HR_MINUTES
        result = call_rpc(client, "extend_session", {
            "p_transaction_id": tx["transaction_id"],
            "p_duration_minutes": duration,
        })
        if result:
            _notify(f"Extended session by {fmt_duration(duration)}.")
            st.rerun()
    else:
        # Past contracted_end: close old tx, open new tx.
        st.session_state[f"new_after_close_{tx['transaction_id']}"] = ext_kind
        st.session_state[f"closing_{tx['transaction_id']}"] = True
        st.rerun()


def _render_close_flow(client: Client, tx: dict) -> None:
    """V2 item 9 — explicit close-order flow with cash tendered if cash."""
    tx_id = tx["transaction_id"]
    state = tx["state"]

    with st.container(border=True):
        st.markdown(f"### Close Order — {tx['customer_name']}")
        projected_total = state["projected_total_centavos"]
        st.markdown(f"**Amount Due (incl. pending auto-extensions):** {fmt_centavos(projected_total)}")

        cash_tendered_centavos: int | None = None
        if tx["payment_method"] == "CASH":
            stored_tendered = tx.get("cash_tendered_centavos") or 0
            additional_needed = max(0, projected_total - stored_tendered)
            if additional_needed > 0:
                if stored_tendered > 0:
                    st.markdown(f"Previously collected: **{fmt_centavos(stored_tendered)}**")
                tendered_php = st.number_input(
                    "Additional Cash Tendered (₱)" if stored_tendered > 0 else "Cash Tendered (₱)",
                    min_value=0.00, step=10.00, format="%.2f",
                    key=f"close_tendered_{tx_id}",
                    value=float(additional_needed) / 100.0,
                )
                extra_centavos = int(round(tendered_php * 100))
                cash_tendered_centavos = stored_tendered + extra_centavos
                change = cash_tendered_centavos - projected_total
                col_a, col_b = st.columns(2)
                col_a.metric("Total Due", fmt_centavos(projected_total))
                col_b.metric("Change", fmt_centavos(change) if change >= 0 else "INSUFFICIENT")
                disabled = change < 0
            else:
                st.info(f"Payment already collected: {fmt_centavos(projected_total)}")
                cash_tendered_centavos = stored_tendered if stored_tendered > 0 else projected_total
                disabled = False
        else:
            disabled = False

        c1, c2 = st.columns([1, 4])
        with c1:
            if st.button("✓ Confirm Close", key=f"confirm_close_{tx_id}", type="primary", disabled=disabled):
                params: dict[str, Any] = {"p_transaction_id": tx_id}
                if cash_tendered_centavos is not None:
                    params["p_cash_tendered_centavos"] = cash_tendered_centavos
                result = call_rpc(client, "checkout_session", params)
                if result:
                    row = result[0] if isinstance(result, list) else result
                    st.success(
                        f"Closed. Final: {fmt_centavos(row.get('final_fee_centavos'))}, "
                        f"Change: {fmt_centavos(row.get('change_due_centavos'))}."
                    )
                    # If this close was triggered by an out-of-window extension,
                    # immediately open the new transaction for the same customer.
                    ext_kind = st.session_state.pop(f"new_after_close_{tx_id}", None)
                    if ext_kind:
                        new_tx_id = call_rpc(client, "start_session", {
                            "p_customer_id": tx["customer_id"],
                            "p_initial_kind": ext_kind,
                            "p_payment_method": tx["payment_method"],
                        })
                        if new_tx_id:
                            _notify("New session started for the same customer.")
                    st.session_state.pop(f"closing_{tx_id}", None)
                    st.rerun()
        with c2:
            if st.button("✗ Cancel", key=f"cancel_close_{tx_id}"):
                st.session_state.pop(f"closing_{tx_id}", None)
                st.session_state.pop(f"new_after_close_{tx_id}", None)
                st.rerun()


def _render_void_flow(client: Client, tx: dict) -> None:
    tx_id = tx["transaction_id"]
    with st.container(border=True):
        st.markdown(f"### Void Order — {tx['customer_name']}")
        st.warning("Voiding reverses this transaction. The customer is not charged.")
        reason = st.text_input("Reason for void *", key=f"void_reason_{tx_id}")
        c1, c2 = st.columns([1, 4])
        with c1:
            if st.button("✓ Confirm Void", key=f"confirm_void_{tx_id}", type="primary"):
                if not reason.strip():
                    st.error("Reason is required.")
                else:
                    result = call_rpc(client, "void_session", {
                        "p_transaction_id": tx_id,
                        "p_reason": reason,
                    })
                    if result:
                        _notify("Transaction voided.")
                        st.session_state.pop(f"voiding_{tx_id}", None)
                        st.rerun()
        with c2:
            if st.button("✗ Cancel", key=f"cancel_void_{tx_id}"):
                st.session_state.pop(f"voiding_{tx_id}", None)
                st.rerun()


# Polling fragment for live cross-funnel sync (V2 item 4).
@st.fragment(run_every=POLL_SECONDS)
def staff_tab_active_sessions(client_ref: dict[str, Client]) -> None:
    st.subheader("⏱ Active Sessions")
    sessions = fetch_active_sessions(client_ref["client"])
    render_active_sessions_table(sessions, show_actions=True, client=client_ref["client"])


def staff_tab_cash_management(client: Client, shift: dict) -> None:
    """V2 items 7, 15 — cash injections + payouts, hide expected/variance from staff/manager."""
    st.subheader("💵 Cash Register")

    if not shift.get("shift_id"):
        st.info("No shift is currently open.")
        return

    c1, c2 = st.columns(2)
    c1.metric("Opening Cash", fmt_centavos(shift["opening_cash_centavos"]))
    c2.metric("Shift Opened", fmt_pht(shift["opened_at"]))

    st.divider()

    # Injection / payout entry — visible to staff+.
    st.markdown("### Add Cash Movement")
    mv_col1, mv_col2, mv_col3 = st.columns([1, 1, 2])
    with mv_col1:
        mv_kind = st.radio("Type", ["INJECTION", "PAYOUT"], horizontal=True, key="mv_kind",
                           format_func=lambda k: "💰 Injection (add cash)" if k == "INJECTION" else "💸 Payout (remove cash)")
    with mv_col2:
        mv_amount = st.number_input("Amount (₱)", min_value=0.01, step=10.0, format="%.2f", key="mv_amount")
    with mv_col3:
        mv_reason = st.text_input("Reason *", key="mv_reason",
                                  placeholder="e.g., needed more change / paid refund to customer")
    if st.button("💾 Record Movement", type="primary"):
        if not mv_reason.strip():
            st.error("Reason is required.")
        else:
            res = call_rpc(client, "register_cash_movement", {
                "p_kind": mv_kind,
                "p_amount_centavos": int(round(mv_amount * 100)),
                "p_reason": mv_reason,
            })
            if res:
                _notify(f"Recorded {mv_kind.lower()}: {fmt_centavos(int(round(mv_amount*100)))}")
                st.rerun()

    st.divider()

    # Today's movements list — visible to all who use the cash drawer.
    st.markdown("### Today's Movements")
    try:
        movements = (
            client.table("cash_movements")
            .select("created_at, kind, amount_centavos, reason, actor_role, voided")
            .eq("shift_id", shift["shift_id"])
            .order("created_at", desc=True)
            .execute()
            .data or []
        )
        if movements:
            df = pd.DataFrame(movements)
            df["created_at"] = df["created_at"].apply(fmt_pht)
            df["amount_centavos"] = df["amount_centavos"].apply(fmt_centavos)
            df = df.rename(columns={
                "created_at": "Time",
                "kind": "Type",
                "amount_centavos": "Amount",
                "reason": "Reason",
                "actor_role": "By Role",
                "voided": "Voided",
            })
            st.dataframe(df, use_container_width=True, hide_index=True)
        else:
            st.caption("No cash movements yet today.")
    except Exception as e:
        st.error(f"Failed to load movements: {e}")

    st.divider()

    # Close shift section. NOTE: per V2 item 7, staff/manager do NOT see
    # expected cash or variance. Only the admin sees those.
    st.markdown("### Close Shift")
    active_count = (
        client.table("transactions")
        .select("transaction_id", count="exact")
        .eq("shift_id", shift["shift_id"])
        .eq("status", "ACTIVE")
        .execute()
        .count or 0
    )
    if active_count > 0:
        st.warning(f"⚠ {active_count} session(s) still active. Close them before closing the shift.")
        return

    closing_php = st.number_input(
        "Closing Cash in Register (₱)",
        min_value=0.00, step=1.00, format="%.2f", key="closing_amount",
    )
    if st.button("🔒 Close Shift", type="primary"):
        result = call_rpc(client, "close_shift", {
            "p_shift_id": shift["shift_id"],
            "p_closing_cash_centavos": int(round(closing_php * 100)),
        })
        if result is not None:
            # IMPORTANT: do NOT surface variance to staff/manager.
            # Admin receives it via admin_alerts silently.
            if require_role("admin"):
                _notify(f"Shift closed. Variance: {fmt_centavos(int(result))}")
            else:
                _notify("Shift closed.")
            st.rerun()


def render_staff_dashboard(client: Client, shift: dict) -> None:
    st.title("📋 Staff Dashboard")
    _show_notify()
    tabs = st.tabs(["🧾 New Order", "⏱ Active Sessions", "💵 Cash Register"])
    with tabs[0]:
        staff_tab_new_order(client)
    with tabs[1]:
        # Pass via a dict to keep the fragment-friendly reference stable.
        staff_tab_active_sessions({"client": client})
    with tabs[2]:
        staff_tab_cash_management(client, shift)


# =============================================================================
# SECTION 15 — MANAGER DASHBOARD (extends staff, adds void tab review)
# =============================================================================

def render_manager_dashboard(client: Client, shift: dict) -> None:
    st.title("🔑 Manager Dashboard")
    _show_notify()
    tab_names = ["📋 Staff Features", "❌ Voided / Refunded"]
    tabs = st.tabs(tab_names)
    with tabs[0]:
        # Embedded full staff dashboard.
        sub = st.tabs(["🧾 New Order", "⏱ Active Sessions", "💵 Cash Register"])
        with sub[0]:
            staff_tab_new_order(client)
        with sub[1]:
            staff_tab_active_sessions({"client": client})
        with sub[2]:
            staff_tab_cash_management(client, shift)
    with tabs[1]:
        manager_tab_voided(client)


def manager_tab_voided(client: Client) -> None:
    st.subheader("Recently Voided / Refunded Transactions")
    try:
        txs = (
            client.table("transactions")
            .select("transaction_id, barcode, status, start_time, end_time, payment_method, final_fee_centavos")
            .in_("status", ["VOIDED", "REFUNDED"])
            .order("updated_at", desc=True)
            .limit(50)
            .execute()
            .data or []
        )
        if not txs:
            st.info("No voided or refunded transactions in the recent history.")
            return
        df = pd.DataFrame(txs)
        df["start_time"] = df["start_time"].apply(fmt_pht)
        df["end_time"] = df["end_time"].apply(fmt_pht)
        df["final_fee_centavos"] = df["final_fee_centavos"].apply(fmt_centavos)
        df = df.drop(columns=["transaction_id"])
        df = df.rename(columns={
            "barcode": "Barcode",
            "status": "Status",
            "start_time": "Start Time",
            "end_time": "End Time",
            "payment_method": "Payment",
            "final_fee_centavos": "Final Amount",
        })
        st.dataframe(df, use_container_width=True, hide_index=True)
    except Exception as e:
        st.error(f"Failed to load: {e}")


# =============================================================================
# SECTION 16 — ADMIN DASHBOARD
# =============================================================================

def render_admin_dashboard(client: Client, shift: dict) -> None:
    st.title("🛡 Admin Dashboard")
    _show_notify()
    tabs = st.tabs([
        "📋 Staff Features",
        "❌ Voided / Refunded",
        "📊 Analytics",
        "🚨 Cash Alerts",
        "📜 Daily Cash Log",
        "🛠 Cash Overrides",
        "👥 Create User",
    ])

    with tabs[0]:
        sub = st.tabs(["🧾 New Order", "⏱ Active Sessions", "💵 Cash Register"])
        with sub[0]:
            if not shift.get("shift_id") or shift.get("opening_cash_centavos") is None:
                st.warning("A shift must be open with an opening cash count before creating orders.")
            else:
                staff_tab_new_order(client)
        with sub[1]:
            staff_tab_active_sessions({"client": client})
        with sub[2]:
            admin_tab_cash_register(client, shift)
    with tabs[1]:
        manager_tab_voided(client)
    with tabs[2]:
        admin_tab_analytics(client)
    with tabs[3]:
        admin_tab_alerts(client)
    with tabs[4]:
        admin_tab_daily_cash_log(client)
    with tabs[5]:
        admin_tab_cash_overrides(client)
    with tabs[6]:
        admin_tab_create_user(client)


def admin_tab_cash_register(client: Client, shift: dict) -> None:
    """Admin sees the expected cash & variance, unlike staff/manager."""
    st.subheader("💵 Cash Register (Admin View)")

    if not shift.get("shift_id"):
        st.info("No shift is currently open.")
        amount = st.number_input(
            "Opening Cash in Register (₱)",
            min_value=0.00, step=1.00, format="%.2f", key="admin_open_shift_amount",
        )
        if st.button("💰 Open Shift", type="primary", key="admin_open_shift_btn"):
            result = call_rpc(client, "open_shift", {"p_opening_cash_centavos": int(round(amount * 100))})
            if result:
                _notify("Shift opened.")
                st.rerun()
        return

    c1, c2, c3 = st.columns(3)
    c1.metric("Opening Cash", fmt_centavos(shift["opening_cash_centavos"]))
    c2.metric("Shift Opened", fmt_pht(shift["opened_at"]))

    expected = call_rpc(client, "preview_shift_cash_expected", {"p_shift_id": shift["shift_id"]})
    c3.metric("Expected Cash Now", fmt_centavos(expected) if expected is not None else "—")

    st.divider()

    # Same injection / payout UI as staff.
    st.markdown("### Add Cash Movement")
    mv_col1, mv_col2, mv_col3 = st.columns([1, 1, 2])
    with mv_col1:
        mv_kind = st.radio("Type", ["INJECTION", "PAYOUT"], horizontal=True, key="admin_mv_kind",
                           format_func=lambda k: "💰 Injection" if k == "INJECTION" else "💸 Payout")
    with mv_col2:
        mv_amount = st.number_input("Amount (₱)", min_value=0.01, step=10.0, format="%.2f", key="admin_mv_amount")
    with mv_col3:
        mv_reason = st.text_input("Reason *", key="admin_mv_reason")
    if st.button("💾 Record Movement", type="primary", key="admin_record_movement"):
        if not mv_reason.strip():
            st.error("Reason is required.")
        else:
            res = call_rpc(client, "register_cash_movement", {
                "p_kind": mv_kind,
                "p_amount_centavos": int(round(mv_amount * 100)),
                "p_reason": mv_reason,
            })
            if res:
                _notify("Recorded.")
                st.rerun()

    st.divider()

    # Close shift — admin sees variance directly.
    st.markdown("### Close Shift")
    active_count = (
        client.table("transactions")
        .select("transaction_id", count="exact")
        .eq("shift_id", shift["shift_id"])
        .eq("status", "ACTIVE")
        .execute()
        .count or 0
    )
    if active_count > 0:
        st.warning(f"⚠ {active_count} session(s) still active.")
        return

    if expected is not None:
        st.info(f"Expected closing cash: **{fmt_centavos(expected)}**")
    closing_php = st.number_input(
        "Closing Cash in Register (₱)",
        min_value=0.00, step=1.00, format="%.2f", key="admin_closing_amount",
    )
    if st.button("🔒 Close Shift", type="primary", key="admin_close_shift"):
        result = call_rpc(client, "close_shift", {
            "p_shift_id": shift["shift_id"],
            "p_closing_cash_centavos": int(round(closing_php * 100)),
        })
        if result is not None:
            variance_centavos = int(result)
            if variance_centavos == 0:
                _notify("Shift closed. Cash reconciles exactly.")
            else:
                _notify(f"Shift closed with variance: {fmt_centavos(variance_centavos)}", "warning")
            st.rerun()


def admin_tab_analytics(client: Client) -> None:
    """V2 item 22 — analytics with 1/7/30-day toggle."""
    st.subheader("📊 Revenue Analytics")

    days = st.radio(
        "Timeframe",
        options=[1, 7, 30],
        format_func=lambda d: f"Last {d} day{'s' if d > 1 else ''}",
        horizontal=True,
    )

    summary = call_rpc(client, "analytics_summary", {"p_days": days})
    if summary:
        s = summary[0] if isinstance(summary, list) else summary
        cols = st.columns(4)
        cols[0].metric("Transactions", f"{int(s['tx_count']):,}")
        cols[1].metric("Total Revenue", fmt_centavos(int(s["revenue_centavos"])))
        cols[2].metric("Cash Revenue", fmt_centavos(int(s["cash_revenue_centavos"])))
        cols[3].metric("Online Revenue", fmt_centavos(int(s["online_revenue_centavos"])))

        cols2 = st.columns(3)
        avg_min = float(s["avg_session_minutes"] or 0)
        cols2[0].metric("Avg Session", fmt_duration(int(avg_min)))
        cols2[1].metric("Voided", f"{int(s['voided_count']):,}")
        cols2[2].metric("Refunded", f"{int(s['refunded_count']):,}")

    st.divider()
    st.markdown("### Daily Revenue Breakdown")
    rollup = call_rpc(client, "analytics_revenue_rollup", {"p_days": days})
    if rollup:
        df = pd.DataFrame(rollup)
        df["revenue_php"] = df["revenue_centavos"].apply(lambda c: float(c) / 100.0)
        df["bucket_date"] = pd.to_datetime(df["bucket_date"])
        df = df.sort_values("bucket_date")

        chart_df = df[["bucket_date", "revenue_php"]].rename(
            columns={"bucket_date": "Date", "revenue_php": "Revenue (₱)"}
        ).set_index("Date")
        st.bar_chart(chart_df, height=320)

        display_df = df.copy()
        display_df["revenue_centavos"] = display_df["revenue_centavos"].apply(fmt_centavos)
        display_df["bucket_date"] = display_df["bucket_date"].dt.strftime("%Y-%m-%d")
        display_df = display_df.drop(columns=["revenue_php"])
        display_df = display_df.rename(columns={
            "bucket_date": "Date",
            "tx_count": "Transactions",
            "revenue_centavos": "Revenue",
        })
        st.dataframe(display_df, use_container_width=True, hide_index=True)
    else:
        st.caption("No completed transactions in this timeframe.")


def admin_tab_alerts(client: Client) -> None:
    st.subheader("🚨 Cash Mismatch & System Alerts")
    try:
        alerts = (
            client.table("admin_alerts")
            .select("*")
            .order("created_at", desc=True)
            .limit(100)
            .execute()
            .data or []
        )
        if not alerts:
            st.success("✓ No alerts.")
            return

        unack = [a for a in alerts if not a.get("acknowledged_at")]
        st.markdown(f"**{len(unack)} unacknowledged alert(s).**")

        for a in alerts:
            severity = a["severity"]
            color = {"CRITICAL": "#dc3545", "WARN": "#ffc107", "INFO": "#0d6efd"}[severity]
            ack = a.get("acknowledged_at")
            payload = a.get("payload") or {}

            with st.container(border=True):
                st.markdown(
                    f"<div style='display:flex;gap:8px;align-items:center;'>"
                    f"<span style='background:{color};color:#fff;padding:2px 8px;border-radius:4px;font-weight:bold;'>"
                    f"{severity}</span>"
                    f"<strong>{a['alert_type']}</strong>"
                    f"<span style='color:#666;'>· {fmt_pht(a['created_at'])}</span>"
                    f"</div>",
                    unsafe_allow_html=True,
                )

                if a["alert_type"] == "CASH_MISMATCH":
                    st.markdown(
                        f"Opening: {fmt_centavos(payload.get('opening_cash_centavos'))}  ·  "
                        f"Closing: {fmt_centavos(payload.get('closing_cash_centavos'))}  ·  "
                        f"Expected: {fmt_centavos(payload.get('expected_cash_centavos'))}  ·  "
                        f"Cash Sales: {fmt_centavos(payload.get('cash_revenue_centavos'))}  ·  "
                        f"Injections: {fmt_centavos(payload.get('injections_centavos', 0))}  ·  "
                        f"Payouts: {fmt_centavos(payload.get('payouts_centavos', 0))}  ·  "
                        f"**Variance: {fmt_centavos(payload.get('variance_centavos'))}**"
                    )
                else:
                    st.json(payload)

                if ack:
                    st.caption(f"Acknowledged at {fmt_pht(ack)}")
                else:
                    if st.button("✓ Acknowledge", key=f"ack_{a['alert_id']}"):
                        try:
                            (
                                client.table("admin_alerts")
                                .update({
                                    "acknowledged_at": now_utc().isoformat(),
                                    "acknowledged_by": st.session_state.user["user_id"],
                                })
                                .eq("alert_id", a["alert_id"])
                                .execute()
                            )
                            st.rerun()
                        except Exception as e:
                            st.error(f"Failed to acknowledge: {e}")
    except Exception as e:
        st.error(f"Failed to load alerts: {e}")


def admin_tab_daily_cash_log(client: Client) -> None:
    """V2 item 23 — daily log of all cash actions with timestamp, amount, who."""
    st.subheader("📜 Daily Cash Log")
    when = st.date_input("Date", value=date.today())
    rows = call_rpc(client, "admin_daily_cash_log", {"p_date": when.isoformat()})
    if not rows:
        st.info("No cash actions recorded for this date.")
        return
    df = pd.DataFrame(rows)
    df["occurred_at"] = df["occurred_at"].apply(fmt_pht)
    df["amount_php"] = df["amount_php"].apply(
        lambda v: f"₱{float(v):,.2f}" if v is not None else "—"
    )
    df = df.rename(columns={
        "occurred_at": "When",
        "action": "Action",
        "amount_php": "Amount",
        "actor_name": "By",
        "actor_role": "Role",
        "reason": "Reason",
        "shift_id": "Shift",
    })
    st.dataframe(df, use_container_width=True, hide_index=True)


def admin_tab_cash_overrides(client: Client) -> None:
    """V2 item 14 — admin override of opening or closing cash."""
    st.subheader("🛠 Cash Count Overrides")
    st.caption(
        "Use these only to correct an incorrect opening or closing cash entry. "
        "Voiding requires staff to re-enter the correct amount."
    )

    try:
        shifts = (
            client.table("shifts")
            .select("*")
            .order("opened_at", desc=True)
            .limit(10)
            .execute()
            .data or []
        )
    except Exception as e:
        st.error(f"Failed to load shifts: {e}")
        return

    for s in shifts:
        with st.container(border=True):
            st.markdown(
                f"**Shift `{s['shift_id'][:8]}…`** · "
                f"Status: **{s['status']}** · "
                f"Opened {fmt_pht(s['opened_at'])}"
                + (f" · Closed {fmt_pht(s['closed_at'])}" if s.get('closed_at') else "")
            )
            c1, c2 = st.columns(2)
            c1.markdown(f"Opening: **{fmt_centavos(s.get('opening_cash_centavos'))}**")
            c2.markdown(f"Closing: **{fmt_centavos(s.get('closing_cash_centavos'))}**")

            override_cols = st.columns(2)
            with override_cols[0]:
                if s.get("opening_cash_centavos") is not None:
                    reason = st.text_input(
                        "Reason for voiding opening",
                        key=f"void_open_reason_{s['shift_id']}",
                    )
                    if st.button("Void Opening Cash", key=f"void_open_{s['shift_id']}"):
                        if not reason.strip():
                            st.error("Reason is required.")
                        else:
                            res = call_rpc(client, "admin_void_opening_cash", {
                                "p_shift_id": s["shift_id"],
                                "p_reason": reason,
                            })
                            if res:
                                _notify("Opening cash voided. Awaiting re-entry.")
                                st.rerun()
            with override_cols[1]:
                if s.get("closing_cash_centavos") is not None:
                    reason = st.text_input(
                        "Reason for voiding closing",
                        key=f"void_close_reason_{s['shift_id']}",
                    )
                    if st.button("Void Closing Cash", key=f"void_close_{s['shift_id']}"):
                        if not reason.strip():
                            st.error("Reason is required.")
                        else:
                            res = call_rpc(client, "admin_void_closing_cash", {
                                "p_shift_id": s["shift_id"],
                                "p_reason": reason,
                            })
                            if res:
                                _notify("Closing cash voided. Awaiting re-entry.")
                                st.rerun()


def admin_tab_create_user(client: Client) -> None:
    """V2 missed-item 1 — in-app create-user screen for admins.

    This calls Supabase Auth Admin API via the service role key. The service
    role key MUST be set as a Streamlit secret (NEVER bundled). The form
    creates an auth.users entry AND the corresponding staff_profiles row.
    """
    st.subheader("👥 Create Staff / Manager / Admin Account")
    st.caption(
        "Creates a Supabase Auth user and the matching staff profile. "
        "The user can sign in immediately with the password you set here."
    )

    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or _env("SUPABASE_SERVICE_ROLE_KEY", "")
    if not service_role_key:
        st.error("SUPABASE_SERVICE_ROLE_KEY is not configured. Add it to Streamlit secrets to enable user creation.")
        return

    with st.form("create_user"):
        c1, c2 = st.columns(2)
        new_email = c1.text_input("Email *")
        new_password = c2.text_input("Initial Password *", type="password",
                                     help="At least 6 characters. The user can change it later.")
        display_name = st.text_input("Display Name *")
        role = st.selectbox("Role *", options=["staff", "manager", "admin"])
        submit = st.form_submit_button("Create User", type="primary")
        if submit:
            if not new_email or not new_password or not display_name:
                st.error("All fields are required.")
                return
            if len(new_password) < 6:
                st.error("Password must be at least 6 characters.")
                return
            try:
                admin_cli = create_client(_env("SUPABASE_URL"), service_role_key)
                created = admin_cli.auth.admin.create_user({
                    "email": new_email,
                    "password": new_password,
                    "email_confirm": True,
                })
                if not created or not created.user:
                    st.error("Auth user creation returned no user.")
                    return
                new_user_id = created.user.id

                admin_cli.table("staff_profiles").insert({
                    "user_id": new_user_id,
                    "display_name": display_name,
                    "role": role,
                }).execute()

                st.success(f"Created {role} account: {new_email}")
            except Exception as e:
                st.error(f"Failed to create user: {e}")


# =============================================================================
# SECTION 17 — TOP NAV BAR (replaces sidebar)
# =============================================================================

def render_top_nav() -> None:
    user = st.session_state.user
    cols = st.columns([3, 2, 1])
    with cols[0]:
        st.markdown(f"### 🎮 UBBS")
    with cols[1]:
        st.markdown(
            f"<div style='text-align:right;padding-top:14px;'>"
            f"Signed in as <strong>{user['display_name']}</strong> "
            f"<span style='color:#888;'>· {user['role'].upper()}</span></div>",
            unsafe_allow_html=True,
        )
    with cols[2]:
        st.markdown("<div style='padding-top:8px;'>", unsafe_allow_html=True)
        if st.button("Logout"):
            do_logout()
        st.markdown("</div>", unsafe_allow_html=True)
    st.divider()


# =============================================================================
# SECTION 18 — ROUTER
# =============================================================================

def main() -> None:
    hide_streamlit_chrome()

    # Public route: customer registration via ?page=register.
    page_qp = st.query_params.get("page")
    if page_qp == "register":
        page_customer_registration()
        return

    # Authenticated routes — restore from cookie if present.
    if not restore_session():
        page_login()
        return

    render_top_nav()

    client = st.session_state.supabase
    user = st.session_state.user

    # Mandatory cash gate — applies to ALL roles (staff, manager, admin).
    shift = shift_gate(client)
    if shift is None:
        return

    # Role-based dashboard.
    role = user["role"]
    if role == "admin":
        render_admin_dashboard(client, shift)
    elif role == "manager":
        render_manager_dashboard(client, shift)
    elif role == "staff":
        render_staff_dashboard(client, shift)
    else:
        st.error(f"Unknown role: {role}. Contact an admin.")


if __name__ == "__main__":
    main()
