// ============================================================
//  Supabase Edge Function: notion-sink
//  Pulse diagnostics → Notion  (upsert: ek session = ek row)
//
//  Request body:
//    { reason, report, page_id?, new_events? }
//      - pehli baar: page_id null → naya Notion page banata hai
//      - uske baad : page_id diya → properties update + naye events append
//
//  SECRETS (Supabase → Edge Functions → Secrets):
//    NOTION_TOKEN  = Notion integration token (ntn_… / secret_…)
//    NOTION_DB_ID  = Notion database id
//  Optional:
//    ALLOWED_ORIGIN = https://merry8989-uk.github.io
//
//  Deploy:  supabase functions deploy notion-sink
// ============================================================

const NOTION_TOKEN = Deno.env.get("NOTION_TOKEN") ?? "";
const NOTION_DB_ID = Deno.env.get("NOTION_DB_ID") ?? "";
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";
const NOTION_VERSION = "2022-06-28";

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

const notionHeaders = () => ({
  "Authorization": `Bearer ${NOTION_TOKEN}`,
  "Notion-Version": NOTION_VERSION,
  "Content-Type": "application/json",
});

const paragraph = (content: string) => ({
  object: "block",
  type: "paragraph",
  paragraph: { rich_text: [{ type: "text", text: { content: trunc(content, 2000) } }] },
});

// Split text into ≤2000-char paragraph blocks (Notion limit), capped.
function toBlocks(text: string, maxBlocks = 90) {
  const out: any[] = [];
  let buf = "";
  for (const line of text.split("\n")) {
    if ((buf + line).length > 1800) {
      if (buf) out.push(paragraph(buf));
      if (out.length >= maxBlocks) return out;
      buf = line + "\n";
    } else buf += line + "\n";
  }
  if (buf && out.length < maxBlocks) out.push(paragraph(buf));
  return out;
}

function eventRows(events: any[]) {
  return events.map((l) =>
    `| ${l.timestamp ?? ""} | ${l.log_level ?? ""} | ${l.event_name ?? ""} | ${l.attempt_id ?? ""} | ${
      l.screen_or_route ?? ""
    } | ${trunc(l.properties ? JSON.stringify(l.properties) : "", 140).replace(/\|/g, "\\|")} |`
  ).join("\n");
}

function summaryText(reason: string, r: any, attempts: any[]) {
  const meta = r.meta ?? {}, env = r.environment ?? {}, counters = r.counters ?? {}, vitals = r.vitals ?? {};
  return [
    `Reason: ${reason ?? "report"}`,
    `Session: ${meta.session_id ?? env.session_id ?? ""}`,
    `User (hashed): ${env.user_id ?? "(anonymous)"}`,
    `Started: ${r.session?.started_at ?? ""}`,
    `Env: web · ${env.os ?? ""} · ${env.device_model ?? ""} · ${env.network_type ?? ""} · release ${meta.release_channel ?? ""}`,
    `App: ${meta.app_version ?? ""} · schema ${meta.schema_version ?? ""}`,
    ``,
    `Counters: ${Object.entries(counters).map(([k, v]) => `${k}=${v}`).join(", ")}`,
    `Vitals: ${Object.keys(vitals).length ? Object.entries(vitals).map(([k, v]: any) => `${k}=${v?.value}`).join(", ") : "—"}`,
    `Attempts: ${attempts.length ? attempts.map((a) => `${a.event_name}→${a.outcome}`).join(", ") : "—"}`,
  ].join("\n");
}

function buildProperties(meta: any, env: any, counters: any, r: any) {
  return {
    "Session": { title: [{ text: { content: trunc(meta.session_id ?? env.session_id ?? "session", 120) } }] },
    "Started": { date: { start: r.session?.started_at ?? new Date().toISOString() } },
    "User": { rich_text: [{ text: { content: trunc(env.user_id ?? "—", 100) } }] },
    "Platform": { select: { name: "web" } },
    "OS": { rich_text: [{ text: { content: trunc(env.os ?? "", 100) } }] },
    "Device": { rich_text: [{ text: { content: trunc(env.device_model ?? "", 100) } }] },
    "Network": { select: { name: trunc(env.network_type ?? "unknown", 20) } },
    "App Version": { rich_text: [{ text: { content: trunc(meta.app_version ?? "", 60) } }] },
    "Release": { select: { name: trunc(meta.release_channel ?? "production", 20) } },
    "Events": { number: Number(counters.events ?? env.log_count ?? 0) },
    "Errors": { number: Number(counters.errors ?? 0) },
    "Warnings": { number: Number(counters.warnings ?? 0) },
    "TTFV ms": { number: env.ttfv_ms == null ? null : Number(env.ttfv_ms) },
    "Scroll %": { number: env.scroll_depth == null ? null : Number(env.scroll_depth) },
    "Schema": { rich_text: [{ text: { content: trunc(meta.schema_version ?? "", 20) } }] },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!NOTION_TOKEN || !NOTION_DB_ID) return json({ error: "notion_not_configured" }, 500);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }

  const r = body?.report ?? {};
  const reason = body?.reason ?? "report";
  const meta = r.meta ?? {}, env = r.environment ?? {}, counters = r.counters ?? {};
  const attempts: any[] = Array.isArray(r.attempts) ? r.attempts : [];
  const events: any[] = Array.isArray(body?.new_events) ? body.new_events : (Array.isArray(r.logs) ? r.logs : []);
  const pageId: string | null = body?.page_id ?? null;

  const properties = buildProperties(meta, env, counters, r);

  // ---------- UPDATE existing page (one session = one row) ----------
  if (pageId) {
    const upd = await fetch(`https://api.notion.com/v1/pages/${pageId}`, {
      method: "PATCH", headers: notionHeaders(), body: JSON.stringify({ properties }),
    });
    if (upd.status === 404) {
      // page delete ho gaya → neeche create kar dete hain
    } else if (!upd.ok) {
      const d = await upd.json().catch(() => ({}));
      return json({ error: "notion_update_failed", status: upd.status, detail: d }, 502);
    } else {
      let appended = 0;
      if (events.length) {
        const head = `— update (${reason}) · ${new Date().toISOString()} —\n` +
          `| timestamp | level | event | attempt | screen | properties |\n| --- | --- | --- | --- | --- | --- |\n` +
          eventRows(events);
        const children = toBlocks(head, 90);
        const app = await fetch(`https://api.notion.com/v1/blocks/${pageId}/children`, {
          method: "PATCH", headers: notionHeaders(), body: JSON.stringify({ children }),
        });
        if (!app.ok) {
          const d = await app.json().catch(() => ({}));
          return json({ error: "notion_append_failed", status: app.status, detail: d }, 502);
        }
        appended = events.length;
      }
      return json({ ok: true, page_id: pageId, updated: true, appended });
    }
  }

  // ---------- CREATE new page ----------
  const content = summaryText(reason, r, attempts) + "\n\n## Events (" + events.length + ")\n" +
    `| timestamp | level | event | attempt | screen | properties |\n| --- | --- | --- | --- | --- | --- |\n` + eventRows(events);

  const res = await fetch("https://api.notion.com/v1/pages", {
    method: "POST", headers: notionHeaders(),
    body: JSON.stringify({ parent: { database_id: NOTION_DB_ID }, properties, children: toBlocks(content, 95) }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) return json({ error: "notion_create_failed", status: res.status, detail: data }, 502);
  return json({ ok: true, page_id: data.id, url: data.url, created: true });
});
