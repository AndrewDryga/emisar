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

CREATE TABLE IF NOT EXISTS default.packtest_ddl (
    occurred_at DateTime,
    service String,
    label String DEFAULT 'packtest-canary-ch-ddl-default-316f',
    width FixedString(16) COMMENT 'packtest-canary-ch-ddl-comment-406a'
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (service, occurred_at)
TTL occurred_at + INTERVAL 30 DAY
COMMENT 'packtest-canary-ch-ddl-table-comment-54a9';

-- Identifier parameters must quote reserved words and hyphens as names, not SQL.
CREATE TABLE IF NOT EXISTS default.`select` (id UInt8) ENGINE = Memory;
CREATE DATABASE IF NOT EXISTS `packtest-db`;
CREATE TABLE IF NOT EXISTS `packtest-db`.`table-name` (id UInt8) ENGINE = Memory;
