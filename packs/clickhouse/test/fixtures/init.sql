CREATE TABLE IF NOT EXISTS default.packtest_events (
    occurred_at DateTime,
    service LowCardinality(String),
    duration_ms UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (service, occurred_at);

INSERT INTO default.packtest_events VALUES
    ('2026-07-23 12:00:00', 'portal', 12),
    ('2026-07-23 12:01:00', 'runner', 34),
    ('2026-07-23 12:02:00', 'portal', 56);
