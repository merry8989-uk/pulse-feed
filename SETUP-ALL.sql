-- ============================================================
--  PULSE — POORA DATABASE SETUP (ek hi baar chalao)
--  Supabase → SQL Editor → New query → poora paste → Run
--
--  Isme sab kuch hai: profiles/posts/comments/likes, chat
--  (keys, chats, members, messages), groups, storage buckets,
--  RLS policies, triggers, pg_cron cleanup.
--
--  Idempotent hai — dobara chalane se kuch nahi bigdega.
--  Sirf 'Success' aana chahiye. Neeche tables ki list dikhegi.
-- ============================================================

-- ================= SECTION 1/4 — CORE (profiles, posts, likes) =================
-- ============================================================
--  Pulse — Supabase schema
--  Supabase dashboard -> SQL Editor -> New query -> paste -> Run
--  Ye poora backend ek baar me set kar deta hai:
--    tables (profiles, posts, comments, likes), RLS policies,
--    auto-profile trigger, aur 'media' storage bucket.
-- ============================================================

-- ---------- 1. TABLES ----------

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  name          text not null default 'User',
  handle        text unique,
  bio           text default '',
  emoji         text default '',
  is_anonymous  boolean not null default false,
  created_at    timestamptz not null default now()
);

create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  author      uuid not null references public.profiles(id) on delete cascade,
  type        text not null default 'text',   -- text | photo | video
  text        text default '',
  media_url   text,
  media_path  text,
  media       jsonb not null default '[]'::jsonb,  -- array of {url,path,kind} for carousel / pdf / video
  created_at  timestamptz not null default now()
);

create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts(id) on delete cascade,
  author      uuid not null references public.profiles(id) on delete cascade,
  text        text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.likes (
  post_id     uuid not null references public.posts(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index if not exists posts_created_idx  on public.posts (created_at desc);
create index if not exists posts_author_idx   on public.posts (author);
create index if not exists comments_post_idx  on public.comments (post_id);
create index if not exists likes_post_idx     on public.likes (post_id);

-- ---------- 2. AUTO-CREATE PROFILE ON SIGNUP ----------
-- Jab bhi koi naya user bane (GitHub / email / phone / anonymous),
-- uske liye automatically ek profile row ban jaati hai.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta_name  text;
  base_handle text;
begin
  meta_name := coalesce(
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'user_name',
    'User'
  );
  base_handle := lower(regexp_replace(
    coalesce(new.raw_user_meta_data->>'user_name',
             new.raw_user_meta_data->>'preferred_username',
             split_part(coalesce(new.email,'user'), '@', 1)),
    '[^a-z0-9_]', '', 'g'
  ));
  if base_handle is null or base_handle = '' then base_handle := 'user'; end if;

  insert into public.profiles (id, name, handle, is_anonymous)
  values (
    new.id,
    meta_name,
    base_handle || '_' || substr(new.id::text, 1, 4),
    coalesce(new.is_anonymous, false)
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 3. ROW LEVEL SECURITY ----------

alter table public.profiles enable row level security;
alter table public.posts    enable row level security;
alter table public.comments enable row level security;
alter table public.likes    enable row level security;

-- profiles: sab padh sakte hain, sirf owner likh sakta hai
drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_read   on public.profiles for select using (true);
create policy profiles_insert on public.profiles for insert with check (auth.uid() = id);
create policy profiles_update on public.profiles for update using (auth.uid() = id);

-- posts: sab padh sakte hain, sirf apna post likh/saaf kar sakte hain
drop policy if exists posts_read   on public.posts;
drop policy if exists posts_insert on public.posts;
drop policy if exists posts_update on public.posts;
drop policy if exists posts_delete on public.posts;
create policy posts_read   on public.posts for select using (true);
create policy posts_insert on public.posts for insert with check (auth.uid() = author);
create policy posts_update on public.posts for update using (auth.uid() = author);
create policy posts_delete on public.posts for delete using (auth.uid() = author);

-- comments
drop policy if exists comments_read   on public.comments;
drop policy if exists comments_insert on public.comments;
drop policy if exists comments_delete on public.comments;
create policy comments_read   on public.comments for select using (true);
create policy comments_insert on public.comments for insert with check (auth.uid() = author);
create policy comments_delete on public.comments for delete using (auth.uid() = author);

-- likes
drop policy if exists likes_read   on public.likes;
drop policy if exists likes_insert on public.likes;
drop policy if exists likes_delete on public.likes;
create policy likes_read   on public.likes for select using (true);
create policy likes_insert on public.likes for insert with check (auth.uid() = user_id);
create policy likes_delete on public.likes for delete using (auth.uid() = user_id);

-- ---------- 4. STORAGE (photos + videos) ----------
-- Public bucket 'media'. Har user apne folder me upload karta hai.

insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

drop policy if exists media_read   on storage.objects;
drop policy if exists media_insert on storage.objects;
drop policy if exists media_delete on storage.objects;
create policy media_read   on storage.objects for select using (bucket_id = 'media');
create policy media_insert on storage.objects for insert
  with check (bucket_id = 'media' and auth.role() = 'authenticated');
create policy media_delete on storage.objects for delete
  using (bucket_id = 'media' and owner = auth.uid());

-- ---------- DONE ----------
-- Ab Authentication > Providers me jaake GitHub / Email / Anonymous / Phone enable karo.
-- Phir Project Settings > API se URL + anon key copy karke index.html me daalo.

-- ================= SECTION 2/4 — MEDIA / CAROUSEL =================
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

-- ================= SECTION 3/4 — ANONYMOUS CHAT =================
-- ============================================================
--  Pulse — Anonymous Chat  (keys + temp/permanent chats + messages)
--  Supabase → SQL Editor → New query → paste → Run
--
--  Ek hi baar chalana hai. Idempotent hai (dobara chalane se kuch nahi bigdega).
-- ============================================================

-- ---------- 1. keys (fixed = permanent, temp = expires) ----------
create table if not exists public.chat_keys (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  key        text not null unique,
  kind       text not null check (kind in ('fixed','temp')),
  expires_at timestamptz,
  claimed_by uuid references auth.users(id),
  claimed_at timestamptz,
  revoked    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists chat_keys_owner_idx on public.chat_keys(owner);

-- ---------- 2. chats ----------
create table if not exists public.chats (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null default 'direct' check (kind in ('direct','group')),
  title      text,
  created_by uuid not null references auth.users(id) on delete cascade,
  key_id     uuid references public.chat_keys(id) on delete set null,
  expires_at timestamptz,                    -- null = permanent
  created_at timestamptz not null default now()
);
create index if not exists chats_expiry_idx on public.chats(expires_at);

-- ---------- 3. members ----------
create table if not exists public.chat_members (
  chat_id   uuid not null references public.chats(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members(user_id);

-- ---------- 4. messages (insert-only: koi edit/update nahi) ----------
create table if not exists public.chat_messages (
  id         uuid primary key default gen_random_uuid(),
  chat_id    uuid not null references public.chats(id) on delete cascade,
  sender     uuid not null references auth.users(id) on delete cascade,
  body       text,
  attachment jsonb,
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_chat_idx on public.chat_messages(chat_id, created_at);

-- ---------- 5. helpers ----------
create or replace function public.is_chat_member(cid uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.chat_members m where m.chat_id=cid and m.user_id=auth.uid());
$$;

-- ---------- 6. RLS ----------
alter table public.chat_keys     enable row level security;
alter table public.chats         enable row level security;
alter table public.chat_members  enable row level security;
alter table public.chat_messages enable row level security;

drop policy if exists chat_keys_owner_all on public.chat_keys;
create policy chat_keys_owner_all on public.chat_keys
  for all using (owner = auth.uid()) with check (owner = auth.uid());

-- koi bhi signed-in user unclaimed key ko exact value se dhoondh sake
drop policy if exists chat_keys_lookup on public.chat_keys;
create policy chat_keys_lookup on public.chat_keys
  for select using (claimed_by is null and revoked = false);

drop policy if exists chats_member_read on public.chats;
create policy chats_member_read on public.chats
  for select using (public.is_chat_member(id));
drop policy if exists chats_insert on public.chats;
create policy chats_insert on public.chats
  for insert with check (created_by = auth.uid());
-- sirf chat banane wala delete kar sakta hai
drop policy if exists chats_delete on public.chats;
create policy chats_delete on public.chats
  for delete using (created_by = auth.uid());

drop policy if exists chat_members_read on public.chat_members;
create policy chat_members_read on public.chat_members
  for select using (public.is_chat_member(chat_id));
drop policy if exists chat_members_insert on public.chat_members;
create policy chat_members_insert on public.chat_members
  for insert with check (user_id = auth.uid());

drop policy if exists chat_messages_read on public.chat_messages;
create policy chat_messages_read on public.chat_messages
  for select using (public.is_chat_member(chat_id));
drop policy if exists chat_messages_insert on public.chat_messages;
create policy chat_messages_insert on public.chat_messages
  for insert with check (sender = auth.uid() and public.is_chat_member(chat_id));
-- NOTE: update/delete policy jaan-boojh ke nahi hai → message edit/delete nahi ho sakta.

-- ---------- 7. key claim → chat (ek hi call me) ----------
create or replace function public.claim_chat_key(p_key text)
returns table(chat_id uuid, expires_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare k public.chat_keys; c public.chats;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  select * into k from public.chat_keys
   where key = upper(trim(p_key)) and revoked = false
   for update;
  if not found then raise exception 'key_not_found'; end if;
  if k.claimed_by is not null then raise exception 'key_already_used'; end if;
  if k.owner = auth.uid() then raise exception 'own_key'; end if;
  if k.expires_at is not null and k.expires_at <= now() then raise exception 'key_expired'; end if;

  insert into public.chats(kind, created_by, key_id, expires_at)
  values ('direct', k.owner, k.id, k.expires_at)
  returning * into c;

  insert into public.chat_members(chat_id, user_id) values (c.id, k.owner), (c.id, auth.uid());

  update public.chat_keys set claimed_by = auth.uid(), claimed_at = now() where id = k.id;

  return query select c.id, c.expires_at;
end $$;

-- ---------- 8. expiry purge (temp key + uski chat dono delete) ----------
create or replace function public.purge_expired_chats()
returns integer language plpgsql security definer set search_path=public as $$
declare n integer := 0;
begin
  delete from public.chats where expires_at is not null and expires_at <= now();
  get diagnostics n = row_count;
  delete from public.chat_keys where expires_at is not null and expires_at <= now();
  return n;
end $$;

grant execute on function public.claim_chat_key(text)   to authenticated;
grant execute on function public.purge_expired_chats()  to authenticated;

-- har minute auto-cleanup (agar pg_cron available ho)
do $$
begin
  execute 'create extension if not exists pg_cron';
  perform cron.schedule('pulse_purge_chats', '* * * * *', 'select public.purge_expired_chats();');
exception when others then
  raise notice 'pg_cron setup skipped: %', sqlerrm;
end $$;

-- ---------- 9. chat media bucket (private) ----------
insert into storage.buckets (id, name, public)
values ('chat_media','chat_media', false)
on conflict (id) do nothing;

drop policy if exists chat_media_insert on storage.objects;
create policy chat_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat_media'
              and public.is_chat_member(((storage.foldername(name))[1])::uuid));

drop policy if exists chat_media_read on storage.objects;
create policy chat_media_read on storage.objects for select to authenticated
  using (bucket_id = 'chat_media'
         and public.is_chat_member(((storage.foldername(name))[1])::uuid));

-- ============================================================
--  Kaam ki queries
-- ============================================================
-- select key, kind, expires_at, claimed_by is not null as used from public.chat_keys order by created_at desc;
-- select id, kind, expires_at, created_at from public.chats order by created_at desc;
-- select public.purge_expired_chats();   -- manual cleanup

-- ================= SECTION 4/4 — GROUPS + REALTIME =================
-- ============================================================
--  Pulse — Phase 3: GROUPS + temp groups
--  Supabase → SQL Editor → paste → Run  (chat.sql ke BAAD chalana)
-- ============================================================

-- group key ko uske chat se jodo
alter table public.chat_keys add column if not exists chat_id uuid references public.chats(id) on delete cascade;
create index if not exists chat_keys_chat_idx on public.chat_keys(chat_id);

-- kind me 'group' allow karo
alter table public.chat_keys drop constraint if exists chat_keys_kind_check;
alter table public.chat_keys add  constraint chat_keys_kind_check check (kind in ('fixed','temp','group'));

-- ---------- group key claim (reusable: koi bhi join kar sakta hai) ----------
create or replace function public.claim_group_key(p_key text)
returns table(chat_id uuid, expires_at timestamptz, title text)
language plpgsql security definer set search_path=public as $$
declare k public.chat_keys; c public.chats;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  select * into k from public.chat_keys
   where key = upper(trim(p_key)) and kind = 'group' and revoked = false;
  if not found then raise exception 'key_not_found'; end if;
  if k.expires_at is not null and k.expires_at <= now() then raise exception 'key_expired'; end if;

  select * into c from public.chats where id = k.chat_id;
  if not found then raise exception 'key_not_found'; end if;

  insert into public.chat_members(chat_id, user_id)
  values (c.id, auth.uid())
  on conflict do nothing;

  return query select c.id, c.expires_at, c.title;
end $$;

grant execute on function public.claim_group_key(text) to authenticated;

-- ---------- realtime (live messages; na ho to app poll kar leti hai) ----------
do $$
begin
  alter publication supabase_realtime add table public.chat_messages;
exception when others then
  raise notice 'realtime publication skipped: %', sqlerrm;
end $$;

-- ============================================================
--  Kaam ki queries
-- ============================================================
-- select c.id, c.title, c.expires_at, (select count(*) from public.chat_members m where m.chat_id=c.id) as members
-- from public.chats c where c.kind='group' order by c.created_at desc;
-- select key, chat_id, expires_at, revoked from public.chat_keys where kind='group';

-- ================= VERIFY =================
-- Ye query batayegi ki saari tables ban gayi hain ya nahi:
select table_name from information_schema.tables
 where table_schema='public' order by table_name;

-- Chaahiye: chat_keys, chat_members, chat_messages, chats,
--           comments, likes, posts, profiles
