-- A fresh connection observes backend-exit flushes without a cached snapshot.
-- Require exact counts, including raw NULL for tables without an index.
SELECT 'seq-scans-ready' WHERE
  (SELECT count(*) FROM pg_stat_user_tables WHERE
    (relname = 'packtest_seq_indexless' AND seq_scan = 1 AND idx_scan IS NULL AND seq_tup_read = 100001) OR
    (relname = 'packtest_seq_exact_half' AND seq_scan = 1 AND idx_scan = 1 AND seq_tup_read = 100001) OR
    (relname = 'packtest_seq_threshold' AND seq_scan = 1 AND idx_scan IS NULL AND seq_tup_read = 100000) OR
    (relname = 'packtest_seq_index_dominated' AND seq_scan = 1 AND idx_scan = 2 AND seq_tup_read = 100001)) = 4;
