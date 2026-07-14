\set ON_ERROR_STOP on

-- First run as the built-in emisar administrator after the Cloud SQL IAM and
-- pgAudit flags are enabled. Once pgAudit exists, reruns use the IAM principal's
-- emisar_owner membership and never touch administrator-owned event triggers.
BEGIN;

DO $block$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emisar_owner') THEN
    CREATE ROLE emisar_owner
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END
$block$;

-- The application connects as its IAM principal and assumes this non-login
-- owner role at PostgreSQL startup. Reassignment covers tables, sequences,
-- functions, schemas, and types in the current database.
-- A rerun must skip REASSIGN after pgAudit exists: its superuser-only event
-- triggers cannot be reassigned by a Cloud SQL customer administrator.
SELECT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgaudit') AS pgaudit_absent \gset
\if :pgaudit_absent
-- PostgreSQL 18 gives a CREATEROLE creator ADMIN but not SET/INHERIT on the
-- new role. Add the capabilities needed while database_role is staged.
GRANT emisar_owner TO emisar WITH INHERIT TRUE, SET TRUE;
REASSIGN OWNED BY emisar TO emisar_owner;
ALTER DATABASE emisar OWNER TO emisar_owner;
ALTER SCHEMA public OWNER TO emisar_owner;

-- Install pgAudit only after application ownership has moved. Its extension
-- owns superuser-only event triggers that Cloud SQL correctly refuses to move
-- through REASSIGN OWNED. The retained built-in administrator owns that
-- infrastructure extension; emisar_owner owns all application objects.
CREATE EXTENSION IF NOT EXISTS pgaudit;
\else
\echo 'pgAudit already installed; verifying the completed ownership bootstrap'
SET ROLE emisar_owner;
ALTER DATABASE emisar OWNER TO emisar_owner;
ALTER SCHEMA public OWNER TO emisar_owner;
RESET ROLE;
\endif

COMMIT;
