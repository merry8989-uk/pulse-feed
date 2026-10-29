# Pulse — Supabase backend setup (10 minutes)

Ye app ab **Supabase** se juda hai. Iska matlab: sab users ke posts, likes aur comments
**shared** hote hain — tumhara post doosre user ko bhi dikhega. Media (photo/video)
Supabase Storage me jaata hai.

Abhi tumhare paas 3 files hain:

- `index.html` — poori app (frontend). Isme Supabase URL + key daalni hai.
- `setup.sql` — database ka poora structure (tables, security, storage).
- `SETUP.md` — yahi guide.

---

## Step 1 — Supabase project banao

1. [supabase.com](https://supabase.com) pe jao → **Start your project** → GitHub/email se sign in.
2. **New project** → naam do (jaise `pulse`), ek **database password** set karo (yaad rakho), region **Mumbai / Singapore** chuno (India ke liye fastest).
3. Project banne me ~2 minute lagte hain.

## Step 2 — Database set karo

1. Left sidebar me **SQL Editor** → **New query**.
2. `setup.sql` ki poori file copy karke paste karo → **Run** (ya Ctrl+Enter).
3. "Success" dikhna chahiye. Isse ban jaate hain:
   - tables: `profiles`, `posts`, `comments`, `likes`
   - security (RLS) policies — koi doosre ka post edit/delete nahi kar sakta
   - ek trigger — naya user aate hi apne aap profile ban jaati hai
   - `media` storage bucket — photo/video ke liye

## Step 3 — Login methods enable karo

**Authentication → Providers** me jao:

- **Email** → enable karo. (Login code email pe aayega — magic OTP.)
  - Free Supabase ka built-in email kaam karta hai, par roz sirf ~3-4 emails. Apne users ke liye **Authentication → Emails → SMTP** me apna email provider (Resend/Brevo) lagana better hai.
- **Anonymous** → enable karo (toggle ON). Anonymous login isi se chalta hai.
- **GitHub** (chaho to):
  1. GitHub → Settings → Developer settings → **OAuth Apps** → New OAuth App.
  2. **Homepage URL**: `https://merry8989-uk.github.io/pulse-feed/`
  3. **Authorization callback URL**: `https://<your-project-ref>.supabase.co/auth/v1/callback`
     (`<your-project-ref>` = tumhara project URL ka hissa, jaise `abcdxyz`)
  4. Client ID + Secret ko Supabase ke GitHub provider me paste karke **Save**.
- **Phone** (optional): Supabase me **Twilio** (Account SID, Auth Token, Message Service SID) daalo, tab OTP chalega. Ye paid hota hai.

**Authentication → URL Configuration** me:
- **Site URL**: `https://merry8989-uk.github.io/pulse-feed/`
- **Redirect URLs**: wahi URL add karo.

## Step 4 — URL aur key copy karo

**Project Settings → API** kholo:
- **Project URL** copy karo (jaise `https://abcdxyz.supabase.co`)
- **anon public** key copy karo (lamba key, `eyJ...` se shuru)

## Step 5 — index.html me daalo

`index.html` kholo, upar ye lines dhoondo:

```js
const SUPABASE_URL      = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Apni values daalo aur save karo. Bas — app ab live backend se juda hai.

> **GitHub pe edit karne ka tarika:** repo `pulse-feed` → `index.html` → pencil icon →
> values badlo → **Commit changes**. GitHub Pages ~1 minute me khud naya version live kar dega.

## Step 6 — Test karo

1. Site kholo → **Sign in** → GitHub/email/phone/anonymous se login karo.
2. Ek text/photo/video post karo.
3. Kisi doosre phone/browser me kholo → wahi post feed me dikhna chahiye. ✅

---

## Notes / gotchas

- **`anon` key public hai** — ise code me rakhna safe hai (RLS tumhara data protect karta hai). Par **`service_role` key kabhi** frontend me na daalo.
- **File size:** app 50 MB tak upload allow karta hai. Bade videos ke liye R2/CDN best hai.
- **Free tier limits:** 500 MB database, 1 GB storage, 5 GB bandwidth/month. Chhote launch ke liye kaafi.
- **Anonymous users:** har browser/device ka apna anonymous user hota hai.
- **Email OTP code na aaye?** Spam dekho, ya Supabase ke default email rate-limit (free) ki wajah se ho sakta hai — apna SMTP lagao.

## Aage (optional)

- **Custom domain** — `pulse.in` jaisa. GitHub Pages me: repo → Settings → Pages → Custom domain.
- **Cloudflare R2** — jab video traffic badhe. Supabase Storage ki jagah R2 pe media daalo (egress free). Iske liye ek chhota Cloudflare Worker + presigned upload URL chahiye.
- **Moderation** — open UGC se pehle report/hide feature add karna zaroori (IT Rules 2021).

---

## Update (v2) — multiple photos + PDF posts

App me ab ye features hain:

- **Multiple photos** ek post me — Instagram jaisa **swipeable carousel** (dots + counter ke saath).
- **PDF post** — PDF upload karo, aur post me "Read PDF" button se ek **swipeable reader** khulta hai (page right-to-left swipe ya arrows se badal sakte ho).

Iske liye database me ek naya column chahiye. **Agar tumne pehle `setup.sql` chala diya tha**, to sirf ye ek chhota migration chalao:

1. Supabase → **SQL Editor** → New query.
2. `migrate_v2.sql` paste karke **Run**.

(Agar tum abhi shuru kar rahe ho, to naya `setup.sql` already ye column bana deta hai — migration ki zaroorat nahi.)

Note: PDF reading browser me **PDF.js** (CDN se) se hoti hai — koi extra setup nahi chahiye.

---

## Diagnostics logs — ab sirf LOCAL hain

Diagnostics ka **koi server upload nahi** hai. Saare logs sirf user ke **browser
(localStorage)** me rehte hain — Notion/Supabase sink hata diya gaya hai.

User nikaalne ke liye **⚙️ → Diagnostics** me:
- **Email report** → `br19shc39@gmail.com` pe pehle se bhara hua compose
- **Share** / **Copy**
- **Export** → CSV (Excel), JSON, Markdown, Text
- **Refresh** / **Clean logs**

Isi page pe **category chips** (error / security / performance / api / database /
audit / user_activity / analytics) aur severity filter bhi hain.

**Logs me kya-kya hai:** 12 categories (app, error, security, performance,
user_activity, api, database, audit, analytics, job, infra, trace), 6 severity
levels (trace→fatal), Web Vitals (LCP/CLS/INP/TTFB/FCP), long tasks, memory,
API logs (method/endpoint/status/latency/request_id), audit trail (delete /
profile update / diagnostics toggle), login failures, permission failures.

**Privacy:** email/phone/token/key/file path/filename sab redact; `user_id` sirf
salted hash. Password/token kabhi log nahi hota.

Off karna ho to Settings me **Diagnostics OFF** — collect band.

> `diag_events.sql` aur `diag_events_v2.sql` ab **use nahi hote** (sink hata diya).
> Chaaho to GitHub se delete kar do. Tumhare Supabase project me pehle se bana
> `diag_events` table bhi ab khaali rahega — chaaho to
> `drop table public.diag_events;` chala do.

---

## Anonymous chat (Phase 1)

1. Supabase → **SQL Editor** → New query → **`chat.sql`** paste → **Run**.
2. Bas. Header me **💬** icon, ya profile me **"Anonymous chat"** button se khulega.

Kya-kya hai:
- **Fixed key** (permanent) — ek baar kisi ne use ki, to chat permanent. Sirf banane wala delete kar sakta hai.
- **Temporary keys** — 10 second se lekar jitna chaho. Time khatam = key + poora chat **dono taraf se delete** (pg_cron har minute cleanup karta hai).
- Messages **insert-only** — edit ya delete ka koi raasta nahi (RLS me update/delete policy hi nahi).
- **Koi bhi file**: image, video, audio, PDF, doc, GIF, aur links.
- Private bucket (`chat_media`) — sirf chat members signed URL se dekh sakte hain.

Baaki phases: HD audio/video calls, groups + temp groups, Android app (auto-updater).
