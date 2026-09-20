SET TIME ZONE 'UTC';

DROP TABLE IF EXISTS
    hw2_training_events,
    hw2_customer_features_online,
    hw2_customer_features_offline,
    hw2_purchases,
    hw2_customers,
    hw2_products,
    hw2_stores
CASCADE;


-- BUSINESS ENTITIES

CREATE TABLE hw2_customers (
    customer_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name          VARCHAR(150) NOT NULL,
    email              VARCHAR(255) NOT NULL UNIQUE,
    registration_date  DATE NOT NULL,
    city               VARCHAR(100),

    CONSTRAINT chk_customers_email_format
        CHECK (email LIKE '%_@_%'),

    CONSTRAINT chk_customers_registration_not_future
        CHECK (registration_date <= CURRENT_DATE)
);

COMMENT ON TABLE hw2_customers IS 'бізнес-сутність: клієнт магазину';

CREATE TABLE hw2_products (
    product_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_name  VARCHAR(200) NOT NULL,
    category      VARCHAR(100) NOT NULL,
    price         NUMERIC(10, 2) NOT NULL,
    brand         VARCHAR(100),

    CONSTRAINT chk_products_price_positive
        CHECK (price > 0)
);

COMMENT ON TABLE hw2_products IS 'бізнес-сутність: товар каталогу';

CREATE TABLE hw2_stores (
    store_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    store_name  VARCHAR(150) NOT NULL,
    city        VARCHAR(100),
    store_type  VARCHAR(20),

    CONSTRAINT chk_stores_store_type_domain
        CHECK (store_type IN ('online', 'offline', 'hybrid'))
);

COMMENT ON TABLE hw2_stores IS 'бізнес-сутність: точка продажу (офлайн/онлайн магазин)';


-- BRIDGE TABLE (реалізує N:M hw2_customers <-> hw2_products)

CREATE TABLE hw2_purchases (
    purchase_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   INTEGER NOT NULL,
    product_id    INTEGER NOT NULL,
    store_id      INTEGER NOT NULL,
    purchase_ts   TIMESTAMPTZ NOT NULL,
    quantity      INTEGER NOT NULL DEFAULT 1,
    amount        NUMERIC(10, 2) NOT NULL,

    CONSTRAINT fk_purchases_customer
        FOREIGN KEY (customer_id) REFERENCES hw2_customers (customer_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE,
    
    CONSTRAINT fk_purchases_product
        FOREIGN KEY (product_id) REFERENCES hw2_products (product_id)
        ON DELETE RESTRICT DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT fk_purchases_store
        FOREIGN KEY (store_id) REFERENCES hw2_stores (store_id)
        ON DELETE RESTRICT DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT chk_purchases_quantity_positive
        CHECK (quantity > 0),

    CONSTRAINT chk_purchases_amount_non_negative
        CHECK (amount >= 0)
);

COMMENT ON TABLE hw2_purchases IS 'Bridge-таблиця: реалізує зв''язок N:M між hw2_customers і hw2_products (аналог ratings у MovieLens)';


-- OFFLINE FEATURE STORE LEVEL

CREATE TABLE hw2_customer_features_offline (
    feature_id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id                 INTEGER NOT NULL,
    avg_order_value             NUMERIC(10, 2),
    purchase_count_30d          INTEGER,
    favorite_category           VARCHAR(100),
    days_since_last_purchase    INTEGER,
    valid_from                  TIMESTAMPTZ NOT NULL,
    valid_to                    TIMESTAMPTZ,

    CONSTRAINT fk_features_offline_customer
        FOREIGN KEY (customer_id) REFERENCES hw2_customers (customer_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT chk_features_offline_valid_period
        CHECK (valid_to IS NULL OR valid_to > valid_from),
    
    CONSTRAINT chk_features_offline_purchase_count_non_negative
        CHECK (purchase_count_30d IS NULL OR purchase_count_30d >= 0),

    CONSTRAINT chk_features_offline_days_non_negative
        CHECK (days_since_last_purchase IS NULL OR days_since_last_purchase >= 0)
);

COMMENT ON TABLE hw2_customer_features_offline IS
'OFFLINE LEVEL: історичні (slow-changing) знімки ознак клієнта. Кожен рядок — версія ознак, дійсна у проміжку [valid_from, valid_to). Використовується для генерації тренувальних наборів (point-in-time correctness).';


-- ONLINE FEATURE STORE LEVEL

CREATE TABLE hw2_customer_features_online (
    customer_id                 INTEGER PRIMARY KEY,
    avg_order_value             NUMERIC(10, 2),
    purchase_count_30d          INTEGER,
    favorite_category           VARCHAR(100),
    days_since_last_purchase    INTEGER,
    updated_at                  TIMESTAMPTZ NOT NULL,

    CONSTRAINT fk_features_online_customer
        FOREIGN KEY (customer_id) REFERENCES hw2_customers (customer_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT chk_features_online_purchase_count_non_negative
        CHECK (purchase_count_30d IS NULL OR purchase_count_30d >= 0)
);

COMMENT ON TABLE hw2_customer_features_online IS
'ONLINE LEVEL: поточний (останній) стан ознак клієнта для low-latency inference у реальному часі. Один рядок на клієнта (1:1 з hw2_customers), без історії.';


-- TRAINING EVENTS

CREATE TABLE hw2_training_events (
    event_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id          INTEGER NOT NULL,
    product_id           INTEGER NOT NULL,
    prediction_ts        TIMESTAMPTZ NOT NULL,
    will_purchase_30d    BOOLEAN NOT NULL,

    CONSTRAINT fk_training_events_customer
        FOREIGN KEY (customer_id) REFERENCES hw2_customers (customer_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT fk_training_events_product
        FOREIGN KEY (product_id) REFERENCES hw2_products (product_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE
);

COMMENT ON TABLE hw2_training_events IS
'Точки тренування ML-моделі: момент часу prediction_ts, для якого беруться ознаки (point-in-time join з offline-таблицею) та цільова змінна will_purchase_30d (чи купить клієнт товар протягом 30 днів).';


-- INDEXES ДЛЯ ОСНОВНИХ ACCESS PATTERNS

-- Найчастіший запит: усі покупки клієнта (для розрахунку features та аналітики)
CREATE INDEX idx_purchases_customer_id
    ON hw2_purchases (customer_id);

-- Запит: усі покупки конкретного товару (популярність товару)
CREATE INDEX idx_purchases_product_id
    ON hw2_purchases (product_id);

-- Point-in-time join: для training_event знайти чинну версію offline-ознак
-- клієнта на момент prediction_ts (valid_from <= prediction_ts < valid_to)
CREATE INDEX idx_features_offline_customer_valid_from
    ON hw2_customer_features_offline (customer_id, valid_from DESC);

-- Запит: усі тренувальні події клієнта, впорядковані за часом
CREATE INDEX idx_training_events_customer_prediction_ts
    ON hw2_training_events (customer_id, prediction_ts);
