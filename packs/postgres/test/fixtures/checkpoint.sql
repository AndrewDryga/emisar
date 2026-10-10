SELECT current_setting('server_version_num')::integer >= 170000 AS separate_checkpointer \gset
SELECT pg_stat_reset_shared('bgwriter');
\if :separate_checkpointer
SELECT pg_stat_reset_shared('checkpointer');
\endif
CREATE TABLE packtest_checkpoint AS SELECT i FROM generate_series(1, 10000) i;
CHECKPOINT;
