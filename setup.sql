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
