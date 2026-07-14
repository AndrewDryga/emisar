\set ON_ERROR_STOP on
\if :{?expected_session_user}
\else
  \echo 'expected_session_user is required (pass -v expected_session_user=SERVICE_ACCOUNT_DB_USER)'
  \set expected_session_user ''
\endif

-- Run through the Cloud SQL Auth Proxy as the VM IAM database principal.
-- Expected: session_user is the service-account email without the .gserviceaccount.com
-- suffix. Cloud SQL's database_roles assignment must permit SET ROLE.
SELECT set_config('emisar.expected_session_user', :'expected_session_user', false);

DO $block$
DECLARE
  invalid_role_count bigint;
BEGIN
  IF session_user <> current_setting('emisar.expected_session_user') THEN
    RAISE EXCEPTION 'connected as %, expected IAM principal %', session_user, current_setting('emisar.expected_session_user');
  END IF;
  IF NOT pg_has_role(session_user, 'emisar_owner', 'SET') THEN
    RAISE EXCEPTION '% cannot SET ROLE emisar_owner', session_user;
  END IF;

  SELECT count(*) INTO invalid_role_count
  FROM pg_roles
  WHERE rolname = session_user
    AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin);
  IF invalid_role_count <> 0 THEN
    RAISE EXCEPTION 'IAM principal % has unexpected PostgreSQL privileges', session_user;
  END IF;

  SELECT count(*) INTO invalid_role_count
  FROM pg_roles
  WHERE rolname = 'emisar_owner'
    AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls);
  IF invalid_role_count <> 0 OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emisar_owner') THEN
    RAISE EXCEPTION 'emisar_owner is missing or has login/elevated privileges';
  END IF;
END
$block$;

SET ROLE emisar_owner;
SELECT session_user, current_user;

DO $block$
DECLARE
  failures        bigint;
  extension_count bigint;
  schema_count    bigint;
BEGIN
  SELECT count(*) INTO failures
  FROM pg_database
  WHERE datname = 'emisar' AND pg_get_userbyid(datdba) <> 'emisar_owner';
  IF failures <> 0 OR current_database() <> 'emisar' THEN
    RAISE EXCEPTION 'emisar database ownership verification failed';
  END IF;

  SELECT count(*), count(*) FILTER (WHERE pg_get_userbyid(nspowner) <> 'emisar_owner')
    INTO schema_count, failures
  FROM pg_namespace
  WHERE nspname = 'public';
  IF schema_count <> 1 OR failures <> 0 THEN
    RAISE EXCEPTION 'public schema ownership verification failed (present %, wrong owner %)', schema_count, failures;
  END IF;

  SELECT count(*) INTO failures
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND pg_get_userbyid(c.relowner) <> 'emisar_owner'
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d
      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
    );
  IF failures <> 0 THEN
    RAISE EXCEPTION '% public relations are not owned by emisar_owner', failures;
  END IF;

  SELECT count(*) INTO failures
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_userbyid(p.proowner) <> 'emisar_owner'
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d
      WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
    );
  IF failures <> 0 THEN
    RAISE EXCEPTION '% public functions are not owned by emisar_owner', failures;
  END IF;

  SELECT count(*) INTO failures
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public'
    AND pg_get_userbyid(t.typowner) <> 'emisar_owner'
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d
      WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e'
    );
  IF failures <> 0 THEN
    RAISE EXCEPTION '% public types are not owned by emisar_owner', failures;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE pg_get_userbyid(extowner) <> 'emisar_owner')
    INTO extension_count, failures
  FROM pg_extension
  WHERE extname IN ('citext', 'pgcrypto');
  IF extension_count <> 2 OR failures <> 0 THEN
    RAISE EXCEPTION 'application extension ownership verification failed (present %, wrong owner %)', extension_count, failures;
  END IF;

  -- pgAudit owns superuser-only event triggers and intentionally remains owned
  -- by the retained built-in administrator rather than the application role.
  SELECT count(*) INTO extension_count
  FROM pg_extension
  WHERE extname = 'pgaudit' AND pg_get_userbyid(extowner) = 'emisar';
  IF extension_count <> 1 THEN
    RAISE EXCEPTION 'pgaudit extension is missing or not owned by emisar';
  END IF;

  SELECT count(*) INTO failures
  FROM pg_event_trigger
  WHERE evtname IN ('pgaudit_ddl_command_end', 'pgaudit_sql_drop')
    AND pg_get_userbyid(evtowner) = 'emisar';
  IF failures <> 2 OR (SELECT count(*) FROM pg_event_trigger WHERE evtname LIKE 'pgaudit_%') <> 2 THEN
    RAISE EXCEPTION 'pgaudit event triggers are missing, unexpected, or not owned by emisar';
  END IF;
END
$block$;

-- A migration-capable session must be able to create and remove an object.
-- Keep the probe transactional so a lost client cannot leave the table behind.
BEGIN;
CREATE TABLE emisar_iam_auth_probe (id bigint PRIMARY KEY);
DROP TABLE emisar_iam_auth_probe;
ROLLBACK;
