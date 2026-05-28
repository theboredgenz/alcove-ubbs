-- Store Resend API key in app_config so the trigger can access it
INSERT INTO public.app_config (key, value) VALUES
  ('resend_api_key',    're_jnC3oXRG_KUhRXHbERApfpofACoXguwB5'),
  ('alert_email',       'marvinsy.paomyeon@gmail.com'),
  ('resend_from',       'UBBS Alerts <onboarding@resend.dev>')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- Trigger function: fires on every new admin_alert INSERT
CREATE OR REPLACE FUNCTION notify_admin_on_alert()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $fn$
DECLARE
  v_key    TEXT;
  v_to     TEXT;
  v_from   TEXT;
  v_html   TEXT;
BEGIN
  -- Only fire for CASH_MISMATCH alerts
  IF NEW.kind <> 'CASH_MISMATCH' THEN
    RETURN NEW;
  END IF;

  SELECT value INTO v_key  FROM public.app_config WHERE key = 'resend_api_key';
  SELECT value INTO v_to   FROM public.app_config WHERE key = 'alert_email';
  SELECT value INTO v_from FROM public.app_config WHERE key = 'resend_from';

  IF v_key IS NULL OR v_to IS NULL THEN
    RETURN NEW;
  END IF;

  v_html := format(
    '<h2 style="color:#c0392b;">⚠ UBBS Cash Mismatch Alert</h2>
     <p>A cash mismatch was detected when closing a shift.</p>
     <table style="border-collapse:collapse;width:100%%;">
       <tr><td style="padding:6px;font-weight:bold;">Message</td>
           <td style="padding:6px;">%s</td></tr>
       <tr><td style="padding:6px;font-weight:bold;">Shift ID</td>
           <td style="padding:6px;">%s</td></tr>
       <tr><td style="padding:6px;font-weight:bold;">Time</td>
           <td style="padding:6px;">%s</td></tr>
     </table>
     <p style="color:#888;font-size:12px;margin-top:24px;">
       Log in to the UBBS Admin Dashboard to acknowledge this alert.
     </p>',
    COALESCE(NEW.message, 'Cash mismatch on shift close.'),
    COALESCE(NEW.shift_id::TEXT, '—'),
    TO_CHAR(NOW() AT TIME ZONE 'Asia/Manila', 'Mon DD, YYYY HH12:MI AM')
  );

  PERFORM net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type',  'application/json'
    ),
    body    := jsonb_build_object(
      'from',    v_from,
      'to',      ARRAY[v_to],
      'subject', 'UBBS Alert: Cash Mismatch Detected',
      'html',    v_html
    )
  );

  RETURN NEW;
END;
$fn$;

-- Attach trigger to admin_alerts
DROP TRIGGER IF EXISTS admin_alerts_notify ON public.admin_alerts;
CREATE TRIGGER admin_alerts_notify
  AFTER INSERT ON public.admin_alerts
  FOR EACH ROW
  EXECUTE FUNCTION notify_admin_on_alert();

-- Verify app_config
SELECT key, value FROM public.app_config ORDER BY key;
