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
