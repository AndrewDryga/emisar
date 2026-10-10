-- Setup has exited and flushed its counters. Reset table and index statistics.
SELECT pg_stat_reset_single_table_counters(oid) FROM pg_class
WHERE relname IN ('packtest_seq_indexless', 'packtest_seq_exact_half',
                 'packtest_seq_threshold', 'packtest_seq_index_dominated',
                 'packtest_seq_exact_half_pkey', 'packtest_seq_index_dominated_pkey');
