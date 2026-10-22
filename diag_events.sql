-- ============================================================
--  Pulse — diagnostics sink (Supabase)
--  Supabase → SQL Editor → New query → paste → Run
--
--  Iske baad app ke diagnostics session-reports khud `diag_events`
--  me aane lagenge. Koi extra token / function deploy nahi chahiye.
-- ============================================================

create table if not exists public.diag_events (
  id              uuid primary key default gen_random_uuid(),
  session_id      text not null,
  user_id         text,                 -- salted hash (raw id kabhi nahi)
  platform        text,
  app_version     text,
  schema_version  text,
  release_channel text,
  event_count     integer,
  error_count     integer,
  warning_count   integer,
  ttfv_ms         integer,
  scroll_depth    integer,
  report          jsonb not null,       -- poora session report (events, vitals, attempts)
  created_at      timestamptz not null default now()
);

create index if not exists diag_events_created_idx on public.diag_events (created_at desc);
create index if not exists diag_events_session_idx on public.diag_events (session_id);
create index if not exists diag_events_errors_idx  on public.diag_events (error_count);

-- ---------- security ----------
alter table public.diag_events enable row level security;

-- App sirf INSERT kar sakta hai. SELECT ki koi policy nahi hai,
-- isliye koi user API se doosron ke logs padh nahi sakta —
-- sirf tum dashboard / SQL Editor me dekh sakte ho.
drop policy if exists diag_events_insert on public.diag_events;
create policy diag_events_insert on public.diag_events
  for insert with check (true);

-- ============================================================
--  Kaam ki queries (SQL Editor me paste karke chalao)
-- ============================================================

-- 1) Sabse naye sessions
-- select created_at, session_id, user_id, error_count, event_count
-- from public.diag_events order by created_at desc limit 50;

-- 2) Sabse zyada aane wale events
-- select e->>'event_name' as event, count(*) as n
-- from public.diag_events, jsonb_array_elements(report->'logs') e
-- group by 1 order by n desc limit 20;

-- 3) Sirf errors
-- select created_at, session_id, e->>'event_name' as event, e->'properties' as props
-- from public.diag_events, jsonb_array_elements(report->'logs') e
-- where e->>'log_level' = 'error'
-- order by created_at desc limit 100;

-- 4) Average time-to-first-value aur total sessions
-- select round(avg(ttfv_ms)) as avg_ttfv_ms, count(*) as sessions from public.diag_events;

-- 5) Kitne sessions me rage/dead clicks hue
-- select count(*) filter (where (report->'counters'->>'rageClicks')::int > 0) as with_rage,
--        count(*) filter (where (report->'counters'->>'deadClicks')::int > 0) as with_dead
-- from public.diag_events;

-- Purana data khud delete karna ho to:
-- delete from public.diag_events where created_at < now() - interval '90 days';
