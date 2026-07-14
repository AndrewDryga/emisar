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
BEGIN
  IF session_user <> current_setting('emisar.expected_session_user') THEN
    RAISE EXCEPTION 'connected as %, expected IAM principal %', session_user, current_setting('emisar.expected_session_user');
  END IF;
  IF NOT pg_has_role(session_user, 'emisar_owner', 'SET') THEN
    RAISE EXCEPTION '% cannot SET ROLE emisar_owner', session_user;
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
  WHERE extname IN ('citext', 'pgcrypto', 'pgaudit');
  IF extension_count <> 3 OR failures <> 0 THEN
    RAISE EXCEPTION 'application extension verification failed (present %, wrong owner %)', extension_count, failures;
  END IF;
END
$block$;

-- A migration-capable session must be able to create and remove an object.
CREATE TABLE emisar_iam_auth_probe (id bigint PRIMARY KEY);
DROP TABLE emisar_iam_auth_probe;
