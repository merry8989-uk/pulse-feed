# Pulse → Notion: diagnostics sync setup

Isse **sabhi users ke diagnostics session reports** tumhare Notion database
**“Pulse Diagnostics”** me apne aap aayenge.

```
Pulse app (browser)
   │  POST  { reason, report }
   ▼
Supabase Edge Function  "notion-sink"   ← Notion token yahan chhupa rehta hai
   │  POST  /v1/pages
   ▼
Notion database  "Pulse Diagnostics"
```

**Kyun beech me function?** Website static hai. Agar Notion token seedha
`index.html` me daalo, to wo sabko dikhega aur koi bhi tumhara poora Notion
padh/likh sakta hai. Token sirf server (Edge Function) ke secret me rehta hai.

---

## Pehle se ready

Notion database ban chuka hai:

- **Naam:** Pulse Diagnostics (tumhare Notion ke Private me)
- **URL:** https://app.notion.com/p/a6fb0085c32243acb763f4ec4db28fc6
- **Database ID:** `a6fb0085c32243acb763f4ec4db28fc6`
- Ek row = ek session (poora event log us page ke andar).

---

## Step 1 — Notion integration banao

1. Kholo: **https://www.notion.so/my-integrations**
2. **New integration** → naam `Pulse Diagnostics` → apna workspace select karo → Save.
3. **Internal Integration Secret** copy karo — `ntn_…` (ya purana `secret_…`).
   Isse kahin public na karna — sirf Supabase secret me daalna.

## Step 2 — Database ko integration ke saath share karo

Ye step **zaroori** hai, warna API 404 degi:

1. Notion me **Pulse Diagnostics** database kholo.
2. Upar right me **•••** → **Connections** → **Connect to** → apni `Pulse Diagnostics` integration add karo.

## Step 3 — Edge Function deploy karo

**Option A — Supabase CLI se:**

```bash
supabase functions deploy notion-sink      # repo me supabase/functions/notion-sink/index.ts hai
supabase secrets set NOTION_TOKEN=ntn_xxxxxxxx \
                     NOTION_DB_ID=a6fb0085c32243acb763f4ec4db28fc6 \
                     ALLOWED_ORIGIN=https://merry8989-uk.github.io
```

**Option B — Dashboard se:** Supabase → **Edge Functions** → **Create function**
→ naam `notion-sink` → `notion-sink.ts` ka code paste karo → Deploy →
**Secrets** me upar wali 3 values add karo.

Deploy hone ke baad URL milega:

```
https://naimlzavtlytnrqixffm.supabase.co/functions/v1/notion-sink
```

## Step 4 — App me URL daalo

`index.html` me ye line dhoondo aur apna function URL paste karo:

```js
const NOTION_SINK_URL = "";   // ← yahan https://<ref>.supabase.co/functions/v1/notion-sink
```

GitHub pe edit karke commit kar do — Pages khud redeploy kar dega.

## Step 5 — Test karo

Site kholo → **⚙️ → Diagnostics → 🟦 Send to Notion**. Notion me ek naya row
aana chahiye jisme counters, web vitals, attempts aur saare events honge.

---

## Kab-kab bhejta hai (rate-friendly)

- **Error aane pe** — turant, par 30 second me ek hi baar (debounced).
- **Session end** pe (user tab hide/close kare) — ek baar.
- **Manual** — Diagnostics me “Send to Notion” button.

**Ek session = ek row.** Pehli baar naya row banta hai; uske baad **wahi row
update** hoti hai (counters/vitals refresh) aur naye events us page me **append**
hote hain — duplicate rows nahi bante. Notion API ~3 req/sec allow karta hai,
isliye per-event nahi, per-report bheja jaata hai.

## Views (pehle se bane hue)

- **By user** — table, `User` se grouped (har user ka apna group).
- **By network** — board, `Network` se grouped.
- **With errors** — sirf woh sessions jahan `Errors > 0`.

## Zaroori baatein

- **Consent:** Settings me **Diagnostics OFF** karne se events collect hona
  band + Notion sync band ho jaata hai (aur maujooda logs delete). Default ON.
- **Privacy:** `user_id` sirf salted hash (`u_…`) jaata hai; email/phone/tokens/
  file paths redact ho jaate hain.
- **Testing ke liye beta channel:** URL me `?beta=1` lagao → `release_channel=beta`.
- Notion token **kabhi** `index.html` me na daalo. Sirf Supabase secret me.
