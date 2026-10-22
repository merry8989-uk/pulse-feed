-- ============================================================
--  Pulse — diagnostics v2 (categories + severity + naye fields)
--  Supabase → SQL Editor → New query → paste → Run
--
--  Purana `diag_events` table ho to ye columns add kar dega.
--  Bilkul naya setup ho to pehle `diag_events.sql`, phir ye chalao.
-- ============================================================

alter table public.diag_events add column if not exists app_id          text;
alter table public.diag_events add column if not exists environment     text;
alter table public.diag_events add column if not exists category_counts jsonb;
alter table public.diag_events add column if not exists severity_counts jsonb;
alter table public.diag_events add column if not exists security_events integer default 0;
alter table public.diag_events add column if not exists audit_events    integer default 0;

create index if not exists diag_events_security_idx on public.diag_events (security_events);
create index if not exists diag_events_env_idx      on public.diag_events (environment);

-- ---------- safety: report ka size cap (spam / accident se bachne ke liye) ----------
alter table public.diag_events drop constraint if exists diag_events_size_chk;
alter table public.diag_events add  constraint diag_events_size_chk check (length(report::text) < 400000);

-- ============================================================
--  Kaam ki queries
-- ============================================================

-- 1) Har session ka category breakdown
-- select created_at, session_id, category_counts, severity_counts
-- from public.diag_events order by created_at desc limit 20;

-- 2) Jahan security events hue (failed logins, permission denied)
-- select created_at, session_id, user_id, security_events
-- from public.diag_events where security_events > 0 order by created_at desc limit 50;

-- 3) Jahan audit events hue (delete / profile update / diagnostics toggle)
-- select created_at, session_id, audit_events
-- from public.diag_events where audit_events > 0 order by created_at desc limit 50;

-- 4) Sirf security category ke individual events
-- select created_at, session_id, e->>'event_name' as event, e->>'message' as msg
-- from public.diag_events, jsonb_array_elements(report->'logs') e
-- where e->>'category' = 'security' order by created_at desc limit 100;

-- 5) Sabse zyada aane wale events (category ke saath)
-- select e->>'category' as category, e->>'event_name' as event, count(*) as n
-- from public.diag_events, jsonb_array_elements(report->'logs') e
-- group by 1,2 order by n desc limit 30;

-- 6) Slow API calls (performance category)
-- select created_at, session_id, e->'properties'->>'endpoint' as endpoint,
--        (e->'properties'->>'latency_ms')::int as ms
-- from public.diag_events, jsonb_array_elements(report->'logs') e
-- where e->>'event_name' = 'api_call' and (e->'properties'->>'latency_ms')::int > 3000
-- order by created_at desc limit 50;

-- 7) Retention cleanup (90 din se purana)
-- delete from public.diag_events where created_at < now() - interval '90 days';
