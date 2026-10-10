SET max_parallel_workers_per_gather = 0;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
SELECT count(*) FROM packtest_seq_indexless;
SELECT count(*) FROM packtest_seq_exact_half;
SELECT count(*) FROM packtest_seq_threshold;
SELECT count(*) FROM packtest_seq_index_dominated;
