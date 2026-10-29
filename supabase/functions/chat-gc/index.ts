// ============================================================
//  Supabase Edge Function: chat-gc
//  Orphaned chat files delete karta hai.
//
//  Jab koi temp chat expire hoti hai, `purge_expired_chats()` DB rows
//  (chat + messages) delete kar deta hai — par Storage me padi files
//  reh jaati hain. Ye function unhe saaf karta hai.
//
//  Logic:
//   1. chat_media bucket ke top-level folders (= chat ids) list karo
//   2. jis chat id ka row `chats` me nahi hai → orphan
//   3. us folder ki saari files delete kar do
//   4. 1 ghante se nayi files ko chhod do (in-flight upload se race na ho)
//
//  Deploy:  supabase functions deploy chat-gc
//  Schedule: Supabase → Edge Functions → chat-gc → Schedules → */15 * * * *
//  (SUPABASE_URL aur SUPABASE_SERVICE_ROLE_KEY automatically milte hain)
// ============================================================

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "chat_media";
const MIN_AGE_MS = 60 * 60 * 1000; // 1 hour

const H = {
  "Authorization": `Bearer ${SRK}`,
  "apikey": SRK,
  "Content-Type": "application/json",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function listFolder(prefix: string): Promise<any[]> {
  const r = await fetch(`${SB_URL}/storage/v1/object/list/${BUCKET}`, {
    method: "POST",
    headers: H,
    body: JSON.stringify({ prefix, limit: 1000, offset: 0, sortBy: { column: "name", order: "asc" } }),
  });
  if (!r.ok) return [];
  const d = await r.json().catch(() => []);
  return Array.isArray(d) ? d : [];
}

async function chatExists(id: string): Promise<boolean> {
  const r = await fetch(`${SB_URL}/rest/v1/chats?id=eq.${id}&select=id`, { headers: H });
  if (!r.ok) return true; // conservative: doubt ho to delete mat karo
  const rows = await r.json().catch(() => []);
  return Array.isArray(rows) && rows.length > 0;
}

async function removeObjects(paths: string[]): Promise<number> {
  if (!paths.length) return 0;
  const r = await fetch(`${SB_URL}/storage/v1/object/${BUCKET}`, {
    method: "DELETE",
    headers: H,
    body: JSON.stringify({ prefixes: paths }),
  });
  return r.ok ? paths.length : 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST" && req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  if (!SB_URL || !SRK) return json({ error: "not_configured" }, 500);

  let foldersChecked = 0, orphanFolders = 0, filesDeleted = 0, skippedYoung = 0;

  try {
    const root = await listFolder("");
    // "folders" ke entries me id/metadata nahi hota
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
        if (!isNaN(ts) && now - ts < MIN_AGE_MS) { skippedYoung++; continue; }
        paths.push(`${dir}/${f.name}`);
      }
      filesDeleted += await removeObjects(paths);
    }

    return json({ ok: true, folders_checked: foldersChecked, orphan_folders: orphanFolders, files_deleted: filesDeleted, skipped_young: skippedYoung });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
