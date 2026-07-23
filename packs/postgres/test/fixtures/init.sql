-- Bootstrap a tiny schema so postgres pack actions like analyze_table,
-- index_usage, etc. have something real to look at.
CREATE TABLE IF NOT EXISTS orders (
    id          serial PRIMARY KEY,
    customer    text NOT NULL,
    amount_cents bigint NOT NULL,
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders (customer);
CREATE INDEX IF NOT EXISTS idx_orders_created  ON orders (created_at);

INSERT INTO orders (customer, amount_cents)
SELECT 'cust' || (i % 50), (random() * 10000)::bigint
FROM generate_series(1, 5000) AS i
ON CONFLICT DO NOTHING;

ANALYZE orders;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
