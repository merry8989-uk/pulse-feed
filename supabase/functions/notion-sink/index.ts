// ============================================================
//  Supabase Edge Function: notion-sink
//  Pulse diagnostics → Notion
//
//  Ye function ek "session report" leta hai aur Notion database
//  "Pulse Diagnostics" me ek page (row) banata hai — poore events
//  uske andar.
//
//  SECRETS (Supabase → Project Settings → Edge Functions → Secrets):
//    NOTION_TOKEN  = tumhara Notion integration token (ntn_… / secret_…)
//    NOTION_DB_ID  = Notion database id (32 hex, dashes optional)
//  Optional:
//    ALLOWED_ORIGIN = https://merry8989-uk.github.io  (CORS lock)
//
//  Deploy:  supabase functions deploy notion-sink
//  Notion integration ko us database ke saath SHARE karna zaroori hai.
// ============================================================

const NOTION_TOKEN = Deno.env.get("NOTION_TOKEN") ?? "";
const NOTION_DB_ID = Deno.env.get("NOTION_DB_ID") ?? "";
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const trunc = (v: unknown, n: number) => {
  const s = v == null ? "" : String(v);
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

// Notion rich_text blocks cap at 2000 chars → split content into paragraphs.
function toBlocks(text: string, maxBlocks = 90) {
  const out: any[] = [];
  const lines = text.split("\n");
  let buf = "";
  for (const line of lines) {
    if ((buf + line).length > 1800) {
      if (buf) out.push(paragraph(buf));
      buf = line + "\n";
      if (out.length >= maxBlocks) return out;
    } else {
      buf += line + "\n";
    }
  }
  if (buf && out.length < maxBlocks) out.push(paragraph(buf));
  return out;
}
const paragraph = (content: string) => ({
  object: "block",
  type: "paragraph",
  paragraph: { rich_text: [{ type: "text", text: { content: trunc(content, 2000) } }] },
});

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!NOTION_TOKEN || !NOTION_DB_ID) return json({ error: "notion_not_configured" }, 500);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const r = body?.report ?? body ?? {};
  const meta = r.meta ?? {};
  const env = r.environment ?? {};
  const logs: any[] = Array.isArray(r.logs) ? r.logs : [];
  const attempts: any[] = Array.isArray(r.attempts) ? r.attempts : [];
  const counters = r.counters ?? {};
  const vitals = r.vitals ?? {};

  const eventRows = logs.slice(-300).map((l) =>
    `| ${l.timestamp ?? ""} | ${l.log_level ?? ""} | ${l.event_name ?? ""} | ${l.attempt_id ?? ""} | ${
      l.screen_or_route ?? ""
    } | ${trunc(l.properties ? JSON.stringify(l.properties) : "", 140).replace(/\|/g, "\\|")} |`
  ).join("\n");

  const content = [
    `Reason: ${body?.reason ?? "report"}`,
    ``,
    `## Session`,
    `- session_id: ${meta.session_id ?? env.session_id ?? ""}`,
    `- started: ${r.session?.started_at ?? ""}`,
    `- user (hashed): ${env.user_id ?? "(anonymous)"}`,
    `- platform: web · os: ${env.os ?? ""} · device: ${env.device_model ?? ""}`,
    `- network: ${env.network_type ?? ""} · release: ${meta.release_channel ?? ""}`,
    `- app_version: ${meta.app_version ?? ""} · schema: ${meta.schema_version ?? ""}`,
    ``,
    `## Counters`,
    ...Object.entries(counters).map(([k, v]) => `- ${k}: ${v}`),
    ``,
    `## Web vitals`,
    ...(Object.keys(vitals).length
      ? Object.entries(vitals).map(([k, v]: any) => `- ${k}: ${v?.value}${v?.rating ? ` (${v.rating})` : ""}`)
      : ["- (none yet)"]),
    ``,
    `## Attempts (intent → outcome)`,
    ...(attempts.length
      ? attempts.map((a) => `- ${a.event_name} (${a.attempt_id}) @${a.screen_or_route} → ${a.outcome}`)
      : ["- (none)"]),
    ``,
    `## Events (${logs.length})`,
    `| timestamp | level | event | attempt | screen | properties |`,
    `| --- | --- | --- | --- | --- | --- |`,
    eventRows,
  ].join("\n");

  const payload = {
    parent: { database_id: NOTION_DB_ID },
    properties: {
      "Session": { title: [{ text: { content: trunc(meta.session_id ?? env.session_id ?? "session", 120) } }] },
      "Started": { date: { start: r.session?.started_at ?? new Date().toISOString() } },
      "User": { rich_text: [{ text: { content: trunc(env.user_id ?? "—", 100) } }] },
      "Platform": { select: { name: "web" } },
      "OS": { rich_text: [{ text: { content: trunc(env.os ?? "", 100) } }] },
      "Device": { rich_text: [{ text: { content: trunc(env.device_model ?? "", 100) } }] },
      "Network": { select: { name: trunc(env.network_type ?? "unknown", 20) } },
      "App Version": { rich_text: [{ text: { content: trunc(meta.app_version ?? "", 60) } }] },
      "Release": { select: { name: trunc(meta.release_channel ?? "production", 20) } },
      "Events": { number: logs.length },
      "Errors": { number: Number(counters.errors ?? 0) },
      "Warnings": { number: Number(counters.warnings ?? 0) },
      "TTFV ms": { number: env.ttfv_ms == null ? null : Number(env.ttfv_ms) },
      "Scroll %": { number: env.scroll_depth == null ? null : Number(env.scroll_depth) },
      "Schema": { rich_text: [{ text: { content: trunc(meta.schema_version ?? "", 20) } }] },
    },
    children: toBlocks(content),
  };

  try {
    const res = await fetch("https://api.notion.com/v1/pages", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${NOTION_TOKEN}`,
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) return json({ error: "notion_api_error", status: res.status, detail: data }, 502);
    return json({ ok: true, page_id: data.id, url: data.url });
  } catch (e) {
    return json({ error: "fetch_failed", detail: String(e) }, 502);
  }
});
