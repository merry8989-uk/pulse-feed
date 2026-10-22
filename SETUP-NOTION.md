# (Purana) Pulse → Notion setup — ab use nahi ho raha

Notion wala route **hata diya gaya hai**. App me ab Notion ka koi code nahi hai.

Diagnostics ab **Supabase** me jaate hain — dekho **`SETUP.md`** ka section
“Diagnostics logs (Supabase)” aur file **`diag_events.sql`**.

Summary:
1. Supabase → SQL Editor → `diag_events.sql` paste → Run.
2. Bas — app khud session reports `diag_events` table me bhejta hai.

Repo me `supabase/functions/notion-sink/index.ts` file ab **unused** hai —
chaaho to GitHub se delete kar do (kisi cheez ko asar nahi padega).
