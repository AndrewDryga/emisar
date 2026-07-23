CREATE TABLE IF NOT EXISTS testdb.orders (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    customer VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    amount_cents BIGINT NOT NULL,
    INDEX idx_orders_customer (customer),
    INDEX idx_orders_status (status)
);

INSERT INTO testdb.orders (customer, status, amount_cents)
VALUES
    ('alice', 'paid', 1200),
    ('bob', 'pending', 3400),
    ('carol', 'paid', 5600);

ANALYZE TABLE testdb.orders;
