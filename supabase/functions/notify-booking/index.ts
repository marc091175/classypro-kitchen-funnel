import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/**
 * Notifies the owner when a booking is created.
 *
 * JWT verification is off because the caller is a Postgres trigger, not a user.
 * Instead the function checks the caller's shared secret against the database,
 * using the service-role key Supabase injects here. The secret itself never
 * leaves Postgres.
 *
 * Channels are independent and any combination may be active:
 *   email    - set RESEND_API_KEY + NOTIFY_EMAIL_TO
 *   whatsapp - set WHATSAPP_PROVIDER (meta|twilio) + WHATSAPP_TO + provider keys
 */

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

type Booking = {
  full_name?: string;
  phone?: string;
  email?: string;
  address?: string;
  kitchen_type?: string;
  size?: string;
  budget?: string;
  timeline?: string;
  survey_date?: string;
  survey_slot?: string;
};

async function secretIsValid(candidate: string): Promise<boolean> {
  if (!candidate || !SUPABASE_URL || !SERVICE_KEY) return false;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/verify_notify_secret`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
      },
      body: JSON.stringify({ p_secret: candidate }),
    });
    if (!res.ok) return false;
    return (await res.json()) === true;
  } catch {
    return false;
  }
}

function esc(s: string): string {
  return s.replace(/[&<>"]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));
}

function plainText(b: Booking): string {
  const lines = [
    "New consultation booked",
    "",
    `${b.full_name ?? "Unknown"}`,
    `Phone: ${b.phone ?? "-"}`,
  ];
  if (b.email) lines.push(`Email: ${b.email}`);
  if (b.address) lines.push(`Address: ${b.address}`);
  lines.push(
    "",
    `Survey: ${b.survey_date ?? "-"} at ${b.survey_slot ?? "-"}`,
    "",
    `Project: ${b.kitchen_type ?? "-"}`,
    `Size: ${b.size ?? "-"}`,
    `Budget: ${b.budget ?? "-"}`,
    `Timeline: ${b.timeline ?? "-"}`,
  );
  return lines.join("\n");
}

function whatsappText(b: Booking): string {
  return plainText(b)
    .replace("New consultation booked", "*New consultation booked*")
    .replace(`${b.full_name ?? "Unknown"}`, `*${b.full_name ?? "Unknown"}*`);
}

function htmlBody(b: Booking): string {
  const row = (k: string, v?: string) =>
    v
      ? `<tr><td style="padding:6px 14px 6px 0;color:#6b6f72;font:14px system-ui">${esc(k)}</td>` +
        `<td style="padding:6px 0;font:600 14px system-ui;color:#0d0d0d">${esc(v)}</td></tr>`
      : "";
  return `<div style="font-family:system-ui,sans-serif;max-width:520px">
<h2 style="margin:0 0 4px;font-size:19px;color:#0d0d0d">New consultation booked</h2>
<p style="margin:0 0 18px;color:#6b6f72;font-size:14px">ClassyPro Phils. — classyprophils.asia</p>
<div style="border-left:3px solid #F5C518;padding:2px 0 2px 16px;margin-bottom:20px">
<div style="font:700 17px system-ui;color:#0d0d0d">${esc(b.survey_date ?? "-")} at ${esc(b.survey_slot ?? "-")}</div>
</div>
<table cellpadding="0" cellspacing="0">
${row("Name", b.full_name)}${row("Phone", b.phone)}${row("Email", b.email)}${row("Address", b.address)}
${row("Project", b.kitchen_type)}${row("Size", b.size)}${row("Budget", b.budget)}${row("Timeline", b.timeline)}
</table></div>`;
}

async function sendEmail(b: Booking) {
  const key = Deno.env.get("RESEND_API_KEY");
  const to = Deno.env.get("NOTIFY_EMAIL_TO");
  const from = Deno.env.get("RESEND_FROM") ?? "ClassyPro Bookings <onboarding@resend.dev>";
  if (!key || !to) {
    return {
      ok: false,
      skipped: true,
      missing: [!key && "RESEND_API_KEY", !to && "NOTIFY_EMAIL_TO"].filter(Boolean),
    };
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: to.split(",").map((s) => s.trim()).filter(Boolean),
      subject: `New booking: ${b.full_name ?? "Unknown"} — ${b.survey_date ?? ""} ${b.survey_slot ?? ""}`.trim(),
      text: plainText(b),
      html: htmlBody(b),
    }),
  });
  return { ok: res.ok, status: res.status, detail: (await res.text()).slice(0, 400) };
}

async function sendViaMeta(text: string, b: Booking, to: string) {
  const token = Deno.env.get("WHATSAPP_TOKEN");
  const phoneId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const template = Deno.env.get("WHATSAPP_TEMPLATE");
  const lang = Deno.env.get("WHATSAPP_TEMPLATE_LANG") ?? "en_US";
  if (!token || !phoneId) throw new Error("missing WHATSAPP_TOKEN or WHATSAPP_PHONE_NUMBER_ID");

  // Outside the 24h customer-service window Meta only delivers templates.
  const body = template
    ? {
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: template,
        language: { code: lang },
        components: [{
          type: "body",
          parameters: [
            b.full_name ?? "-",
            b.phone ?? "-",
            `${b.survey_date ?? "-"} ${b.survey_slot ?? ""}`.trim(),
          ].map((t) => ({ type: "text", text: String(t) })),
        }],
      },
    }
    : { messaging_product: "whatsapp", to, type: "text", text: { preview_url: false, body: text } };

  const res = await fetch(`https://graph.facebook.com/v21.0/${phoneId}/messages`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { ok: res.ok, status: res.status, detail: (await res.text()).slice(0, 400) };
}

async function sendViaTwilio(text: string, to: string) {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const auth = Deno.env.get("TWILIO_AUTH_TOKEN");
  const from = Deno.env.get("TWILIO_WHATSAPP_FROM");
  if (!sid || !auth || !from) {
    throw new Error("missing TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN or TWILIO_WHATSAPP_FROM");
  }
  const form = new URLSearchParams({
    From: from.startsWith("whatsapp:") ? from : `whatsapp:${from}`,
    To: to.startsWith("whatsapp:") ? to : `whatsapp:${to}`,
    Body: text,
  });
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${sid}:${auth}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form,
  });
  return { ok: res.ok, status: res.status, detail: (await res.text()).slice(0, 400) };
}

async function sendWhatsApp(b: Booking) {
  const provider = (Deno.env.get("WHATSAPP_PROVIDER") ?? "").toLowerCase();
  const to = Deno.env.get("WHATSAPP_TO") ?? "";
  if (!provider || !to) {
    return {
      ok: false,
      skipped: true,
      missing: [!provider && "WHATSAPP_PROVIDER", !to && "WHATSAPP_TO"].filter(Boolean),
    };
  }
  const text = whatsappText(b);
  try {
    return provider === "twilio"
      ? await sendViaTwilio(text, to)
      : await sendViaMeta(text, b, to);
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Authenticate the caller against the secret held in Postgres.
  if (!(await secretIsValid(req.headers.get("x-webhook-secret") ?? ""))) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let booking: Booking = {};
  try {
    booking = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "bad_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Channels are independent so one failing never suppresses the other.
  const [email, whatsapp] = await Promise.all([
    sendEmail(booking).catch((e) => ({ ok: false, error: String(e) })),
    sendWhatsApp(booking).catch((e) => ({ ok: false, error: String(e) })),
  ]);

  return new Response(
    JSON.stringify({
      delivered: Boolean((email as { ok?: boolean }).ok || (whatsapp as { ok?: boolean }).ok),
      email,
      whatsapp,
      preview: plainText(booking),
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
