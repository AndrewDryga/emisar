CREATE TABLE packtest_vacuum_progress (
    id integer PRIMARY KEY,
    payload text NOT NULL
) WITH (autovacuum_enabled = false);
INSERT INTO packtest_vacuum_progress
SELECT i, repeat('vacuum-fixture-', 75) FROM generate_series(1, 10000) i;
DELETE FROM packtest_vacuum_progress WHERE id % 2 = 0;
