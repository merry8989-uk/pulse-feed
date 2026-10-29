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
