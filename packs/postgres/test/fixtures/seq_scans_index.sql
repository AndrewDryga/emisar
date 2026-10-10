SET max_parallel_workers_per_gather = 0;
SET enable_seqscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
SELECT id FROM packtest_seq_exact_half WHERE id = 1;
SELECT id FROM packtest_seq_index_dominated WHERE id = 1;
SELECT id FROM packtest_seq_index_dominated WHERE id = 2;
