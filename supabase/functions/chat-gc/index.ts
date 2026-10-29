// ============================================================
//  Supabase Edge Function: chat-gc
//  Temp chat / group destroy hone par uski SAARI files delete karta hai.
//
//  2 kaam:
//   1. QUEUE DRAIN — `chat_gc_queue` me pade exact paths delete karta hai.
//      (chat delete hote hi DB trigger wahan path daal deta hai)
//   2. FOLDER SCAN (fallback) — jo files queue me nahi aayi (purani), unhe
//      orphan folder se dhoondh ke delete karta hai.
//
//  Cron: har minute.
// ============================================================

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "chat_media";
const SCAN_MIN_AGE_MS = 2 * 60 * 1000;   // fallback scan me sirf 2 min purani files

const H = {
  "Authorization": `Bearer ${SRK}`,
  "apikey": SRK,
  "Content-Type": "application/json",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function listFolder(prefix: string): Promise<any[]> {
  const r = await fetch(`${SB_URL}/storage/v1/object/list/${BUCKET}`, {
    method: "POST", headers: H,
    body: JSON.stringify({ prefix, limit: 1000, offset: 0, sortBy: { column: "name", order: "asc" } }),
  });
  if (!r.ok) return [];
  const d = await r.json().catch(() => []);
  return Array.isArray(d) ? d : [];
}

async function chatExists(id: string): Promise<boolean> {
  const r = await fetch(`${SB_URL}/rest/v1/chats?id=eq.${id}&select=id`, { headers: H });
  if (!r.ok) return true;
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows.length > 0;
}

async function removeObjects(paths: string[]): Promise<boolean> {
  if (!paths.length) return true;
  const r = await fetch(`${SB_URL}/storage/v1/object/${BUCKET}`, {
    method: "DELETE", headers: H, body: JSON.stringify({ prefixes: paths }),
  });
  return r.ok;
}

/* ---------- 1. queue drain (deterministic) ---------- */
async function drainQueue() {
  const r = await fetch(`${SB_URL}/rest/v1/chat_gc_queue?select=id,path,attempts&order=queued_at.asc&limit=200`, { headers: H });
  if (!r.ok) return { queue_deleted: 0, queue_failed: 0 };
  const rows: any[] = await r.json().catch(() => []);
  if (!rows.length) return { queue_deleted: 0, queue_failed: 0 };

  const paths = rows.map((x) => x.path).filter(Boolean);
  const ok = await removeObjects(paths);

  if (ok) {
    const ids = rows.map((x) => x.id).join(",");
    await fetch(`${SB_URL}/rest/v1/chat_gc_queue?id=in.(${ids})`, { method: "DELETE", headers: H });
    return { queue_deleted: paths.length, queue_failed: 0 };
  }

  // fail hua → attempts badhao, agle run me dobara try
  for (const x of rows) {
    await fetch(`${SB_URL}/rest/v1/chat_gc_queue?id=eq.${x.id}`, {
      method: "PATCH",
      headers: { ...H, "Prefer": "return=minimal" },
      body: JSON.stringify({ attempts: (x.attempts || 0) + 1 }),
    });
  }
  return { queue_deleted: 0, queue_failed: paths.length };
}

/* ---------- 2. fallback: orphan folders ---------- */
async function scanOrphans() {
  let foldersChecked = 0, orphanFolders = 0, filesDeleted = 0, skippedYoung = 0;
  const root = await listFolder("");
  const dirs = root
    .filter((e) => !e.id || !e.metadata)
    .map((e) => e.name)
    .filter((n) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(n));

  for (const dir of dirs) {
    foldersChecked++;
    if (await chatExists(dir)) continue;
    orphanFolders++;

    const files = await listFolder(dir);
    const now = Date.now();
    const paths: string[] = [];
    for (const f of files) {
      if (!f.id) continue;
      const ts = Date.parse(f.updated_at || f.created_at || "");
      if (!isNaN(ts) && now - ts < SCAN_MIN_AGE_MS) { skippedYoung++; continue; }
      paths.push(`${dir}/${f.name}`);
    }
    if (await removeObjects(paths)) filesDeleted += paths.length;
  }
  return { folders_checked: foldersChecked, orphan_folders: orphanFolders, files_deleted: filesDeleted, skipped_young: skippedYoung };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST" && req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (!SB_URL || !SRK) return json({ error: "not_configured" }, 500);

  try {
    const q = await drainQueue();
    const s = await scanOrphans();
    return json({ ok: true, ...q, ...s });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
