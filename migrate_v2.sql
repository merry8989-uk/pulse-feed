-- ============================================================
--  Pulse v2 migration — multiple photos (carousel) + PDF posts
--  Ye SIRF tab chalao jab tumne pehle setup.sql chala diya ho.
--  Supabase -> SQL Editor -> New query -> paste -> Run
-- ============================================================

alter table public.posts
  add column if not exists media jsonb not null default '[]'::jsonb;

-- 'media' ek array hai. Har item aisa dikhta hai:
--   {"url": "https://.../file.jpg", "path": "<user-id>/<uuid>.jpg", "kind": "image"}
--   kind = "image" | "video" | "pdf"
--
-- Ek post me:
--   - 1 image            -> single photo
--   - 2+ images          -> swipeable carousel (IG jaisa)
--   - 1 video            -> video post
--   - 1 pdf              -> PDF post (swipe reader ke saath)
--
-- Purane posts (jo sirf media_url use karte the) automatically chalte rahenge —
-- app dono ko handle karta hai. Isliye kuch data migrate karne ki zaroorat nahi.
