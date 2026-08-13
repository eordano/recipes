-- Firecrawl "NuQ" Postgres-backed queue schema.
--
-- Vendored from https://github.com/firecrawl/firecrawl/blob/main/apps/nuq-postgres/nuq.sql
-- The Firecrawl image ships no migrations; the worker assumes this schema
-- already exists. Upstream's deploy story is a dedicated nuq-postgres
-- container, but this module runs Firecrawl against an existing shared
-- Postgres, so we apply the SQL ourselves from a systemd one-shot.
--
-- Differences from upstream:
--   * `ALTER SYSTEM SET ...` cluster-wide tuning (checkpoint/WAL/bgwriter/IO)
--     is removed -- the target Postgres may be shared with other tenants, and
--     the stock defaults are fine for a typical crawl load. Re-add it if you
--     run a dedicated cluster.
--   * `cron.unschedule(jobname)` sweep before scheduling, so the init is
--     idempotent on every pg_cron version (pre-1.6 cron.schedule errors on
--     duplicate jobname rather than upserting).
--
-- The DB role that Firecrawl connects as is passed in by the caller as the
-- psql variable `dbrole` (psql -v dbrole=<role>), so the grants at the bottom
-- can be applied without hard-coding a role name.
--
-- Fully idempotent; safe to re-run on every boot.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE SCHEMA IF NOT EXISTS nuq;

DO $$ BEGIN
  CREATE TYPE nuq.job_status AS ENUM ('queued', 'active', 'completed', 'failed');
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE nuq.group_status AS ENUM ('active', 'completed', 'cancelled');
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

-- Idempotency: drop any previously scheduled nuq jobs so re-runs don't
-- depend on pg_cron's upsert-by-jobname semantics (added in pg_cron 1.6).
DO $$
DECLARE
  j text;
BEGIN
  FOR j IN
    SELECT jobname FROM cron.job
    WHERE jobname LIKE 'nuq\_%' ESCAPE '\'
       OR jobname = 'cron_job_run_details_prune'
  LOOP
    PERFORM cron.unschedule(j);
  END LOOP;
END $$;

CREATE TABLE IF NOT EXISTS nuq.queue_scrape (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  status nuq.job_status NOT NULL DEFAULT 'queued'::nuq.job_status,
  data jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  priority int NOT NULL DEFAULT 0,
  lock uuid,
  locked_at timestamp with time zone,
  stalls integer,
  finished_at timestamp with time zone,
  listen_channel_id text,
  returnvalue jsonb,
  failedreason text,
  owner_id uuid,
  group_id uuid,
  CONSTRAINT queue_scrape_pkey PRIMARY KEY (id)
);

ALTER TABLE nuq.queue_scrape
SET (autovacuum_vacuum_scale_factor = 0.01,
     autovacuum_analyze_scale_factor = 0.01,
     autovacuum_vacuum_cost_limit = 10000,
     autovacuum_vacuum_cost_delay = 0);

CREATE INDEX IF NOT EXISTS queue_scrape_active_locked_at_idx ON nuq.queue_scrape USING btree (locked_at) WHERE (status = 'active'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_queued_optimal_2_idx ON nuq.queue_scrape (priority ASC, created_at ASC, id) WHERE (status = 'queued'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_failed_created_at_idx ON nuq.queue_scrape USING btree (created_at) WHERE (status = 'failed'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_completed_standalone_created_at_idx ON nuq.queue_scrape USING btree (created_at) WHERE (status = 'completed'::nuq.job_status AND group_id IS NULL);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_failed_standalone_created_at_idx ON nuq.queue_scrape USING btree (created_at) WHERE (status = 'failed'::nuq.job_status AND group_id IS NULL);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_group_id_idx ON nuq.queue_scrape (group_id) WHERE group_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_group_owner_mode_idx ON nuq.queue_scrape (group_id, owner_id) WHERE ((data->>'mode') = 'single_urls');
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_group_mode_status_idx ON nuq.queue_scrape (group_id, status) WHERE ((data->>'mode') = 'single_urls');
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_group_completed_listing_idx ON nuq.queue_scrape (group_id, finished_at ASC, created_at ASC) WHERE (status = 'completed'::nuq.job_status AND (data->>'mode') = 'single_urls');
CREATE INDEX IF NOT EXISTS idx_queue_scrape_group_status ON nuq.queue_scrape (group_id, status) WHERE status IN ('active', 'queued');

CREATE TABLE IF NOT EXISTS nuq.queue_scrape_backlog (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  data jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  priority int NOT NULL DEFAULT 0,
  listen_channel_id text,
  owner_id uuid,
  group_id uuid,
  times_out_at timestamptz,
  CONSTRAINT queue_scrape_backlog_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS nuq_queue_scrape_backlog_owner_id_idx ON nuq.queue_scrape_backlog (owner_id);
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_backlog_group_mode_idx ON nuq.queue_scrape_backlog (group_id) WHERE ((data->>'mode') = 'single_urls');
CREATE INDEX IF NOT EXISTS nuq_queue_scrape_backlog_times_out_at_idx ON nuq.queue_scrape_backlog (times_out_at);
CREATE INDEX IF NOT EXISTS idx_queue_scrape_backlog_group_id ON nuq.queue_scrape_backlog (group_id);

SELECT cron.schedule('nuq_queue_scrape_clean_completed', '*/5 * * * *', $$
  DELETE FROM nuq.queue_scrape WHERE nuq.queue_scrape.status = 'completed'::nuq.job_status AND nuq.queue_scrape.created_at < now() - interval '1 hour' AND group_id IS NULL;
$$);

SELECT cron.schedule('nuq_queue_scrape_clean_failed', '*/5 * * * *', $$
  DELETE FROM nuq.queue_scrape WHERE nuq.queue_scrape.status = 'failed'::nuq.job_status AND nuq.queue_scrape.created_at < now() - interval '6 hours' AND group_id IS NULL;
$$);

SELECT cron.schedule('nuq_queue_scrape_lock_reaper', '15 seconds', $$
  UPDATE nuq.queue_scrape SET status = 'queued'::nuq.job_status, lock = null, locked_at = null, stalls = COALESCE(stalls, 0) + 1 WHERE nuq.queue_scrape.locked_at <= now() - interval '1 minute' AND nuq.queue_scrape.status = 'active'::nuq.job_status AND COALESCE(nuq.queue_scrape.stalls, 0) < 9;
  WITH stallfail AS (UPDATE nuq.queue_scrape SET status = 'failed'::nuq.job_status, lock = null, locked_at = null, stalls = COALESCE(stalls, 0) + 1 WHERE nuq.queue_scrape.locked_at <= now() - interval '1 minute' AND nuq.queue_scrape.status = 'active'::nuq.job_status AND COALESCE(nuq.queue_scrape.stalls, 0) >= 9 RETURNING id)
  SELECT pg_notify('nuq.queue_scrape', (id::text || '|' || 'failed'::text)) FROM stallfail;
$$);

SELECT cron.schedule('nuq_queue_scrape_backlog_reaper', '* * * * *', $$
  SET statement_timeout = '50s';
  DELETE FROM nuq.queue_scrape_backlog
  WHERE nuq.queue_scrape_backlog.times_out_at < now();
$$);

SELECT cron.schedule('nuq_reindex_queue_scrape_pkey',                    '0 2 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.queue_scrape_pkey;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_active_locked_at',        '20 2 * * *', $$REINDEX INDEX CONCURRENTLY nuq.queue_scrape_active_locked_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_queued_optimal_2',        '40 2 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_queued_optimal_2_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_failed_created_at',       '0 3 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_failed_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_group_owner_mode',        '40 3 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_group_owner_mode_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_group_mode_status',       '0 4 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_group_mode_status_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_group_completed_listing', '20 4 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_group_completed_listing_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_group_status',            '40 4 * * *', $$REINDEX INDEX CONCURRENTLY nuq.idx_queue_scrape_group_status;$$);

SELECT cron.schedule('nuq_reindex_queue_scrape_backlog_pkey',            '0 5 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.queue_scrape_backlog_pkey;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_backlog_owner_id',        '20 5 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_backlog_owner_id_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_backlog_group_mode',      '40 5 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_backlog_group_mode_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_backlog_group_id',        '0 6 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.idx_queue_scrape_backlog_group_id;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_backlog_times_out_at',    '20 6 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_backlog_times_out_at_idx;$$);

SELECT cron.schedule('nuq_reindex_queue_scrape_completed_standalone',    '40 6 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_completed_standalone_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_failed_standalone',       '40 8 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_failed_standalone_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_scrape_group_id',                '40 9 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_scrape_group_id_idx;$$);

SELECT cron.schedule('nuq_maintenance_watchdog', '* * * * *', $$
  SELECT pg_cancel_backend(pid)
  FROM pg_stat_activity
  WHERE backend_type = 'client backend'
    AND query ILIKE 'REINDEX INDEX CONCURRENTLY nuq.%'
    AND now() - query_start > interval '18 minutes';
$$);

CREATE TABLE IF NOT EXISTS nuq.queue_crawl_finished (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  status nuq.job_status NOT NULL DEFAULT 'queued'::nuq.job_status,
  data jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  priority int NOT NULL DEFAULT 0,
  lock uuid,
  locked_at timestamp with time zone,
  stalls integer,
  finished_at timestamp with time zone,
  listen_channel_id text,
  returnvalue jsonb,
  failedreason text,
  owner_id uuid,
  group_id uuid,
  CONSTRAINT queue_crawl_finished_pkey PRIMARY KEY (id)
);

ALTER TABLE nuq.queue_crawl_finished
SET (autovacuum_vacuum_scale_factor = 0.01,
     autovacuum_analyze_scale_factor = 0.01,
     autovacuum_vacuum_cost_limit = 10000,
     autovacuum_vacuum_cost_delay = 0);

CREATE INDEX IF NOT EXISTS queue_crawl_finished_active_locked_at_idx ON nuq.queue_crawl_finished USING btree (locked_at) WHERE (status = 'active'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_queued_optimal_2_idx ON nuq.queue_crawl_finished (priority ASC, created_at ASC, id) WHERE (status = 'queued'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_failed_created_at_idx ON nuq.queue_crawl_finished USING btree (created_at) WHERE (status = 'failed'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_completed_created_at_idx ON nuq.queue_crawl_finished USING btree (created_at) WHERE (status = 'completed'::nuq.job_status);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_completed_standalone_created_at_idx ON nuq.queue_crawl_finished USING btree (created_at) WHERE (status = 'completed'::nuq.job_status AND group_id IS NULL);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_failed_standalone_created_at_idx ON nuq.queue_crawl_finished USING btree (created_at) WHERE (status = 'failed'::nuq.job_status AND group_id IS NULL);
CREATE INDEX IF NOT EXISTS nuq_queue_crawl_finished_group_id_idx ON nuq.queue_crawl_finished (group_id) WHERE group_id IS NOT NULL;

SELECT cron.schedule('nuq_queue_crawl_finished_clean_completed', '*/5 * * * *', $$
  DELETE FROM nuq.queue_crawl_finished WHERE nuq.queue_crawl_finished.status = 'completed'::nuq.job_status AND nuq.queue_crawl_finished.created_at < now() - interval '1 hour' AND group_id IS NULL;
$$);

SELECT cron.schedule('nuq_queue_crawl_finished_clean_failed', '*/5 * * * *', $$
  DELETE FROM nuq.queue_crawl_finished WHERE nuq.queue_crawl_finished.status = 'failed'::nuq.job_status AND nuq.queue_crawl_finished.created_at < now() - interval '6 hours' AND group_id IS NULL;
$$);

SELECT cron.schedule('nuq_queue_crawl_finished_lock_reaper', '15 seconds', $$
  UPDATE nuq.queue_crawl_finished SET status = 'queued'::nuq.job_status, lock = null, locked_at = null, stalls = COALESCE(stalls, 0) + 1 WHERE nuq.queue_crawl_finished.locked_at <= now() - interval '1 minute' AND nuq.queue_crawl_finished.status = 'active'::nuq.job_status AND COALESCE(nuq.queue_crawl_finished.stalls, 0) < 9;
  WITH stallfail AS (UPDATE nuq.queue_crawl_finished SET status = 'failed'::nuq.job_status, lock = null, locked_at = null, stalls = COALESCE(stalls, 0) + 1 WHERE nuq.queue_crawl_finished.locked_at <= now() - interval '1 minute' AND nuq.queue_crawl_finished.status = 'active'::nuq.job_status AND COALESCE(nuq.queue_crawl_finished.stalls, 0) >= 9 RETURNING id)
  SELECT pg_notify('nuq.queue_crawl_finished', (id::text || '|' || 'failed'::text)) FROM stallfail;
$$);

SELECT cron.schedule('nuq_reindex_queue_crawl_finished_pkey',                 '0 7 * * *',   $$REINDEX INDEX CONCURRENTLY nuq.queue_crawl_finished_pkey;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_active_locked_at',     '20 7 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.queue_crawl_finished_active_locked_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_queued_optimal_2',     '40 7 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_queued_optimal_2_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_failed_created_at',    '0 8 * * *',   $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_failed_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_completed_created_at', '20 8 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_completed_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_completed_standalone', '0 9 * * *',   $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_completed_standalone_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_failed_standalone',    '20 9 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_failed_standalone_created_at_idx;$$);
SELECT cron.schedule('nuq_reindex_queue_crawl_finished_group_id',             '0 10 * * *',  $$REINDEX INDEX CONCURRENTLY nuq.nuq_queue_crawl_finished_group_id_idx;$$);
SELECT cron.schedule('nuq_reindex_group_crawl_completed_expires_at',          '20 10 * * *', $$REINDEX INDEX CONCURRENTLY nuq.nuq_group_crawl_completed_expires_at_idx;$$);

CREATE TABLE IF NOT EXISTS nuq.group_crawl (
  id uuid NOT NULL,
  status nuq.group_status NOT NULL DEFAULT 'active'::nuq.group_status,
  created_at timestamptz NOT NULL DEFAULT now(),
  owner_id uuid NOT NULL,
  ttl int8 NOT NULL DEFAULT 86400000,
  expires_at timestamptz,
  CONSTRAINT group_crawl_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_group_crawl_status ON nuq.group_crawl (status) WHERE status = 'active'::nuq.group_status;
CREATE INDEX IF NOT EXISTS nuq_group_crawl_completed_expires_at_idx ON nuq.group_crawl (expires_at) WHERE status = 'completed'::nuq.group_status;

SELECT cron.schedule('nuq_group_crawl_finished', '15 seconds', $$
  WITH finished_groups AS (
    UPDATE nuq.group_crawl
    SET status = 'completed'::nuq.group_status,
        expires_at = now() + MAKE_INTERVAL(secs => nuq.group_crawl.ttl / 1000)
    WHERE status = 'active'::nuq.group_status
      AND NOT EXISTS (
        SELECT 1 FROM nuq.queue_scrape
        WHERE nuq.queue_scrape.status IN ('active', 'queued')
          AND nuq.queue_scrape.group_id = nuq.group_crawl.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM nuq.queue_scrape_backlog
        WHERE nuq.queue_scrape_backlog.group_id = nuq.group_crawl.id
      )
    RETURNING id, owner_id
  )
  INSERT INTO nuq.queue_crawl_finished (data, owner_id, group_id)
  SELECT '{}'::jsonb, finished_groups.owner_id, finished_groups.id
  FROM finished_groups;
$$);

SELECT cron.schedule('nuq_group_crawl_clean', '* * * * *', $$
  SET statement_timeout = '90s';
  WITH victims AS (
    SELECT id FROM nuq.group_crawl
    WHERE status = 'completed'::nuq.group_status
      AND expires_at < now()
    ORDER BY expires_at
    LIMIT 500
    FOR UPDATE SKIP LOCKED
  ), cleaned_groups AS (
    DELETE FROM nuq.group_crawl
    WHERE id IN (SELECT id FROM victims)
    RETURNING id
  ), cleaned_jobs_queue_scrape AS (
    DELETE FROM nuq.queue_scrape
    WHERE nuq.queue_scrape.group_id IN (SELECT id FROM cleaned_groups)
  ), cleaned_jobs_queue_scrape_backlog AS (
    DELETE FROM nuq.queue_scrape_backlog
    WHERE nuq.queue_scrape_backlog.group_id IN (SELECT id FROM cleaned_groups)
  ), cleaned_jobs_crawl_finished AS (
    DELETE FROM nuq.queue_crawl_finished
    WHERE nuq.queue_crawl_finished.group_id IN (SELECT id FROM cleaned_groups)
  )
  SELECT 1;
$$);

SELECT cron.schedule('cron_job_run_details_prune', '0 * * * *', $$
  DELETE FROM cron.job_run_details WHERE start_time < now() - interval '24 hours';
$$);

-- The init runs as postgres (superuser, owns the nuq schema and everything in
-- it). The Firecrawl api+worker containers, however, connect as a separate DB
-- role -- which by default has no privileges on the nuq schema and gets
-- "permission denied for schema nuq" (42501) on getJobToProcess. Upstream's
-- deployment runs the worker as postgres itself, so it doesn't need this; here
-- we have a dedicated role (services.postgresql.ensureUsers). The role name is
-- supplied by the caller as psql variable `dbrole`.
GRANT USAGE ON SCHEMA nuq TO :"dbrole";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA nuq TO :"dbrole";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA nuq TO :"dbrole";
-- Default privileges so future tables (e.g. when the vendored SQL is updated
-- to a newer upstream revision) are reachable without re-grant.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA nuq GRANT ALL ON TABLES TO :"dbrole";
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA nuq GRANT ALL ON SEQUENCES TO :"dbrole";
