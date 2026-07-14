\set ON_ERROR_STOP on

-- Run once as the existing built-in emisar user after the Cloud SQL IAM and
-- pgAudit flags are enabled. Keep pgaudit.log=none until this transaction and
-- the IAM login verification have succeeded.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgaudit;

DO $block$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emisar_owner') THEN
    CREATE ROLE emisar_owner
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END
$block$;

-- PostgreSQL 18 gives a CREATEROLE creator ADMIN but not SET/INHERIT on the
-- new role. Keep that automatic membership and add the two capabilities the
-- password rollback session needs while database_role=emisar_owner is staged.
GRANT emisar_owner TO emisar WITH INHERIT TRUE, SET TRUE;

-- The application connects as its IAM principal and assumes this non-login
-- owner role at PostgreSQL startup. Reassignment covers tables, sequences,
-- functions, schemas, and types in the current database.
REASSIGN OWNED BY emisar TO emisar_owner;
ALTER DATABASE emisar OWNER TO emisar_owner;
ALTER SCHEMA public OWNER TO emisar_owner;

COMMIT;
