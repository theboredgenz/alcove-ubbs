// supabase/functions/send-receipt/index.ts
//
// Receipt email sender. Invoked by a DB trigger on transactions.status
// flipping ACTIVE -> COMPLETED. Builds an HTML receipt and sends via Resend.
//
// Required env (set via `supabase secrets set`):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
//   CRON_SECRET                   (matches app.cron_secret in postgres)
//   RESEND_API_KEY                (from resend.com dashboard)
//   RESEND_FROM_ADDRESS           e.g., "UBBS Receipts <receipts@yourdomain.com>"
//                                 The sending domain MUST be verified in Resend.
//
// Deploy:
//   supabase functions deploy send-receipt --no-verify-jwt
//
// V1 Resend-not-delivering debugging checklist:
//   1. Confirm RESEND_API_KEY is set: `supabase secrets list`
//   2. Confirm RESEND_FROM_ADDRESS uses a domain VERIFIED in Resend dashboard.
//      Unverified domains silently bounce.
//   3. Check Resend dashboard "Emails" tab for delivery status.
//   4. Tail Edge Function logs: `supabase functions logs send-receipt --tail`
//   5. Confirm the trigger fires: query audit_log for CHECKOUT_SESSION rows.
//   6. Confirm pg_net is enabled and app.functions_base_url + app.cron_secret
//      are set on the database.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const RESEND_FROM_ADDRESS =
  Deno.env.get("RESEND_FROM_ADDRESS") ?? "UBBS Receipts <onboarding@resend.dev>";

const supabase = createClient(
  SUPABASE_URL ?? "",
  SUPABASE_SERVICE_ROLE_KEY ?? "",
  { auth: { persistSession: false } },
);

function authOk(req: Request): boolean {
  const header = req.headers.get("Authorization") ?? "";
  return header === `Bearer ${CRON_SECRET}`;
}

function fmtCentavos(c: number | null | undefined): string {
  if (c === null || c === undefined) return "—";
  const sign = c < 0 ? "-" : "";
  const abs = Math.abs(c);
  const peso = Math.floor(abs / 100);
  const cents = abs % 100;
  return `${sign}₱${peso.toLocaleString()}.${String(cents).padStart(2, "0")}`;
}

function fmtPHT(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleString("en-PH", {
    timeZone: "Asia/Manila",
    year: "numeric", month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit",
    hour12: true,
  });
}

function lineItemLabel(kind: string): string {
  switch (kind) {
    case "INITIAL_1HR":          return "1-Hour Session";
    case "INITIAL_5HR":          return "5-Hour Session";
    case "EXTENSION_MANUAL":     return "Manual Extension";
    case "EXTENSION_AUTO_GRACE": return "Overlimit Hour (Auto)";
    default:                     return kind;
  }
}

interface LineItem {
  kind: string;
  duration_minutes: number;
  amount_centavos: number;
  created_at: string;
}

interface ReceiptPayload {
  transaction_id: string;
  barcode: string;
  status: string;
  start_time: string;
  end_time: string;
  actual_checkout_time: string | null;
  payment_method: string;
  final_fee_centavos: number;
  cash_tendered_centavos: number | null;
  change_given_centavos: number | null;
  customer: {
    customer_id: string;
    first_name: string | null;
    last_name: string | null;
    email: string | null;
  };
  line_items: LineItem[];
}

function renderReceiptHtml(p: ReceiptPayload): string {
  const customerName = [p.customer.first_name, p.customer.last_name]
    .filter(Boolean)
    .join(" ") || "Customer";

  const lineItemsHtml = p.line_items
    .map((li) => `
      <tr>
        <td style="padding:8px 0;border-bottom:1px solid #eee;">
          ${lineItemLabel(li.kind)}
          <div style="color:#888;font-size:12px;">${li.duration_minutes} min</div>
        </td>
        <td style="padding:8px 0;border-bottom:1px solid #eee;text-align:right;">
          ${fmtCentavos(li.amount_centavos)}
        </td>
      </tr>`)
    .join("");

  const cashSection = p.payment_method === "CASH"
    ? `
      <tr>
        <td style="padding:6px 0;">Cash Tendered</td>
        <td style="padding:6px 0;text-align:right;">${fmtCentavos(p.cash_tendered_centavos)}</td>
      </tr>
      <tr>
        <td style="padding:6px 0;">Change Given</td>
        <td style="padding:6px 0;text-align:right;">${fmtCentavos(p.change_given_centavos)}</td>
      </tr>`
    : "";

  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>UBBS Receipt</title></head>
<body style="font-family:Arial,sans-serif;background:#f6f6f6;margin:0;padding:24px;">
  <div style="max-width:560px;margin:0 auto;background:#fff;padding:32px;border-radius:8px;">
    <h1 style="margin:0 0 4px 0;font-size:22px;">UBBS Receipt</h1>
    <p style="color:#666;margin:0 0 24px 0;font-size:13px;">
      Barcode: <code>${p.barcode}</code>
    </p>

    <p>Hi ${customerName},</p>
    <p>Thank you for your visit. Here is your transaction summary:</p>

    <table style="width:100%;border-collapse:collapse;margin:16px 0;">
      <tr>
        <td style="padding:6px 0;color:#666;">Start Time</td>
        <td style="padding:6px 0;text-align:right;">${fmtPHT(p.start_time)}</td>
      </tr>
      <tr>
        <td style="padding:6px 0;color:#666;">End Time</td>
        <td style="padding:6px 0;text-align:right;">${fmtPHT(p.end_time)}</td>
      </tr>
      <tr>
        <td style="padding:6px 0;color:#666;">Checkout</td>
        <td style="padding:6px 0;text-align:right;">${fmtPHT(p.actual_checkout_time)}</td>
      </tr>
      <tr>
        <td style="padding:6px 0;color:#666;">Payment</td>
        <td style="padding:6px 0;text-align:right;">${p.payment_method}</td>
      </tr>
    </table>

    <table style="width:100%;border-collapse:collapse;margin:16px 0;">
      <thead>
        <tr style="border-bottom:2px solid #333;">
          <th style="text-align:left;padding:8px 0;">Item</th>
          <th style="text-align:right;padding:8px 0;">Amount</th>
        </tr>
      </thead>
      <tbody>${lineItemsHtml}</tbody>
      <tfoot>
        <tr>
          <td style="padding:12px 0;font-weight:bold;font-size:16px;">Total Paid</td>
          <td style="padding:12px 0;font-weight:bold;font-size:16px;text-align:right;">
            ${fmtCentavos(p.final_fee_centavos)}
          </td>
        </tr>
        ${cashSection}
      </tfoot>
    </table>

    <p style="color:#888;font-size:12px;margin-top:32px;">
      This is an automated receipt. Keep this email for your records.
    </p>
  </div>
</body></html>`;
}

async function sendViaResend(to: string, subject: string, html: string): Promise<{ id?: string; error?: string }> {
  if (!RESEND_API_KEY) {
    return { error: "RESEND_API_KEY is not configured" };
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: RESEND_FROM_ADDRESS,
      to: [to],
      subject,
      html,
    }),
  });

  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    return { error: `Resend ${res.status}: ${JSON.stringify(body)}` };
  }
  return { id: body.id };
}

Deno.serve(async (req: Request): Promise<Response> => {
  const startedAt = new Date().toISOString();

  if (!authOk(req)) {
    return new Response(
      JSON.stringify({ ok: false, error: "unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  let transactionId: string;
  try {
    const body = await req.json();
    transactionId = body.transaction_id;
    if (!transactionId) throw new Error("transaction_id is required");
  } catch (err) {
    return new Response(
      JSON.stringify({ ok: false, error: `bad request: ${err}` }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  try {
    const { data, error } = await supabase.rpc("build_receipt_payload", {
      p_transaction_id: transactionId,
    });
    if (error) throw error;
    if (!data) throw new Error("transaction not found");

    const payload = data as ReceiptPayload;
    const recipient = payload.customer.email;

    if (!recipient) {
      console.log("send_receipt_skipped_no_email", { transactionId, startedAt });
      return new Response(
        JSON.stringify({ ok: true, skipped: "no recipient email" }),
        { headers: { "Content-Type": "application/json" } },
      );
    }

    const subject = `UBBS Receipt — ${fmtCentavos(payload.final_fee_centavos)}`;
    const html = renderReceiptHtml(payload);
    const result = await sendViaResend(recipient, subject, html);

    if (result.error) {
      console.error("send_receipt_resend_failed", { transactionId, error: result.error });
      return new Response(
        JSON.stringify({ ok: false, error: result.error }),
        { status: 502, headers: { "Content-Type": "application/json" } },
      );
    }

    console.log("send_receipt_ok", { transactionId, resend_id: result.id, to: recipient });
    return new Response(
      JSON.stringify({ ok: true, resend_id: result.id, to: recipient }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("send_receipt_failed", { transactionId, startedAt, error: message });
    return new Response(
      JSON.stringify({ ok: false, error: message }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
