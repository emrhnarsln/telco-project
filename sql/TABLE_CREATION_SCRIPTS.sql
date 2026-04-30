-- =============================================================
-- TABLE CREATION SCRIPTS
-- Project  : Telco Project – i2i Systems
-- Database : Oracle XE 21c
-- Schema   : APP_USER (telco)
-- =============================================================
-- Execution order matters because of FK dependencies:
--   1. TARIFFS  (no dependencies)
--   2. CUSTOMERS (depends on TARIFFS)
--   3. MONTHLY_STATS (depends on CUSTOMERS)
--
-- Safe to run multiple times: each table is dropped first with
-- CASCADE CONSTRAINTS so FK references do not block the drop.
-- =============================================================


-- -------------------------------------------------------------
-- STEP 0 – Session setup
-- -------------------------------------------------------------
-- Tell SQL*Plus / DBeaver how to interpret DATE literals from
-- the CSV files (DD/MM/YYYY format).
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';
ALTER SESSION SET NLS_LANGUAGE   = 'AMERICAN';


-- -------------------------------------------------------------
-- STEP 1 – Drop existing tables (reverse dependency order)
-- -------------------------------------------------------------

-- MONTHLY_STATS must be dropped before CUSTOMERS
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE MONTHLY_STATS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF; -- -942 = table does not exist
END;
/

-- CUSTOMERS must be dropped before TARIFFS
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE CUSTOMERS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE TARIFFS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/


-- =============================================================
-- TABLE: TARIFFS
-- =============================================================
-- Lookup / reference table for the four available tariff plans.
-- Every CUSTOMERS row points to exactly one tariff.
-- Limits of 0 (zero) mean the package does not include that
-- resource (e.g. Kurumsal SMS has no data or minute allowance).
-- =============================================================

CREATE TABLE TARIFFS (
    TARIFF_ID    NUMBER(2)      NOT NULL,   -- natural PK: 1-4 in current dataset
    NAME         VARCHAR2(100)  NOT NULL,   -- human-readable tariff name (unique)
    MONTHLY_FEE  NUMBER(10, 2)  NOT NULL,   -- recurring charge in local currency (TRY)
    DATA_LIMIT   NUMBER(10, 2)  DEFAULT 0 NOT NULL,  -- data allowance in MB (0 = not included)
    MINUTE_LIMIT NUMBER(6)      DEFAULT 0 NOT NULL,  -- voice allowance in minutes
    SMS_LIMIT    NUMBER(6)      DEFAULT 0 NOT NULL,  -- SMS allowance

    -- ── Constraints ──────────────────────────────────────────
    CONSTRAINT PK_TARIFFS
        PRIMARY KEY (TARIFF_ID),

    CONSTRAINT UQ_TARIFFS_NAME
        UNIQUE (NAME),                                -- tariff names must be distinct

    CONSTRAINT CHK_TARIFFS_FEE
        CHECK (MONTHLY_FEE >= 0),

    CONSTRAINT CHK_TARIFFS_DATA
        CHECK (DATA_LIMIT >= 0),

    CONSTRAINT CHK_TARIFFS_MINUTE
        CHECK (MINUTE_LIMIT >= 0),

    CONSTRAINT CHK_TARIFFS_SMS
        CHECK (SMS_LIMIT >= 0)
);

-- Table / column comments (visible in DBeaver and data dictionaries)
COMMENT ON TABLE  TARIFFS              IS 'Reference table for available telecom tariff plans.';
COMMENT ON COLUMN TARIFFS.TARIFF_ID   IS 'Surrogate primary key for the tariff.';
COMMENT ON COLUMN TARIFFS.NAME        IS 'Commercial name of the tariff plan (must be unique).';
COMMENT ON COLUMN TARIFFS.MONTHLY_FEE IS 'Monthly subscription fee in TRY.';
COMMENT ON COLUMN TARIFFS.DATA_LIMIT  IS 'Monthly data allowance in MB. 0 means not included.';
COMMENT ON COLUMN TARIFFS.MINUTE_LIMIT IS 'Monthly voice-call allowance in minutes. 0 means not included.';
COMMENT ON COLUMN TARIFFS.SMS_LIMIT   IS 'Monthly SMS allowance. 0 means not included.';


-- =============================================================
-- TABLE: CUSTOMERS
-- =============================================================
-- Core entity table.  Each row represents one subscriber.
-- TARIFF_ID is a FK back to TARIFFS; the database will reject
-- any attempt to assign a non-existent tariff to a customer.
-- =============================================================

CREATE TABLE CUSTOMERS (
    CUSTOMER_ID NUMBER(6)     NOT NULL,   -- natural PK from source system (1–10 000)
    NAME        VARCHAR2(100) NOT NULL,   -- subscriber first name (UTF-8 safe in AL32UTF8 db)
    CITY        VARCHAR2(100) NOT NULL,   -- city of residence (upper-case in source data)
    SIGNUP_DATE DATE          NOT NULL,   -- date the subscriber was onboarded
    TARIFF_ID   NUMBER(2)     NOT NULL,   -- FK → TARIFFS

    -- ── Constraints ──────────────────────────────────────────
    CONSTRAINT PK_CUSTOMERS
        PRIMARY KEY (CUSTOMER_ID),

    CONSTRAINT FK_CUSTOMER_TARIFF
        FOREIGN KEY (TARIFF_ID)
        REFERENCES TARIFFS (TARIFF_ID)
        -- No ON DELETE CASCADE: deleting a tariff should be
        -- blocked if customers are still subscribed to it.
);

COMMENT ON TABLE  CUSTOMERS             IS 'Subscriber master table. One row per customer.';
COMMENT ON COLUMN CUSTOMERS.CUSTOMER_ID IS 'Unique identifier for the customer (source: billing system).';
COMMENT ON COLUMN CUSTOMERS.NAME        IS 'Customer first name. May contain Turkish characters.';
COMMENT ON COLUMN CUSTOMERS.CITY        IS 'City of residence stored in upper-case.';
COMMENT ON COLUMN CUSTOMERS.SIGNUP_DATE IS 'Date (DD/MM/YYYY) the customer first subscribed.';
COMMENT ON COLUMN CUSTOMERS.TARIFF_ID   IS 'FK to TARIFFS. Indicates the current active tariff plan.';


-- =============================================================
-- TABLE: MONTHLY_STATS
-- =============================================================
-- One row per customer per billing month.  In the current
-- dataset this is a 1-to-1 relationship (one month of data).
-- The UNIQUE constraint on CUSTOMER_ID enforces that each
-- customer appears at most once in the monthly snapshot.
--
-- NOTE: The source CSV contains an ID column that happens to
-- match CUSTOMER_ID in value; both are preserved to stay
-- faithful to the original schema.  The gaps in ID values
-- (e.g. ID 6, 10, 31 … are absent) represent the customers
-- whose monthly records are missing (see query 4.1).
-- =============================================================

CREATE TABLE MONTHLY_STATS (
    ID             NUMBER(6)     NOT NULL,   -- record identifier (mirrors CUSTOMER_ID in source)
    CUSTOMER_ID    NUMBER(6)     NOT NULL,   -- FK → CUSTOMERS
    DATA_USAGE     NUMBER(10, 2) DEFAULT 0 NOT NULL,  -- consumed data in MB
    MINUTE_USAGE   NUMBER(6)     DEFAULT 0 NOT NULL,  -- consumed voice minutes
    SMS_USAGE      NUMBER(6)     DEFAULT 0 NOT NULL,  -- consumed SMS count
    PAYMENT_STATUS VARCHAR2(10)  NOT NULL,            -- PAID | LATE | UNPAID

    -- ── Constraints ──────────────────────────────────────────
    CONSTRAINT PK_MONTHLY_STATS
        PRIMARY KEY (ID),

    CONSTRAINT FK_STATS_CUSTOMER
        FOREIGN KEY (CUSTOMER_ID)
        REFERENCES CUSTOMERS (CUSTOMER_ID),

    -- Each customer can appear at most once in the monthly snapshot
    CONSTRAINT UQ_STATS_CUSTOMER
        UNIQUE (CUSTOMER_ID),

    -- Guard against invalid payment state values
    CONSTRAINT CHK_PAYMENT_STATUS
        CHECK (PAYMENT_STATUS IN ('PAID', 'LATE', 'UNPAID')),

    -- Usage figures cannot be negative
    CONSTRAINT CHK_STATS_DATA
        CHECK (DATA_USAGE >= 0),

    CONSTRAINT CHK_STATS_MINUTE
        CHECK (MINUTE_USAGE >= 0),

    CONSTRAINT CHK_STATS_SMS
        CHECK (SMS_USAGE >= 0)
);

COMMENT ON TABLE  MONTHLY_STATS                IS 'Monthly usage and payment snapshot. One row per customer per billing cycle.';
COMMENT ON COLUMN MONTHLY_STATS.ID             IS 'Record PK. Gaps in values indicate customers with missing monthly records.';
COMMENT ON COLUMN MONTHLY_STATS.CUSTOMER_ID    IS 'FK to CUSTOMERS. A UNIQUE constraint enforces the 1-to-1 monthly relationship.';
COMMENT ON COLUMN MONTHLY_STATS.DATA_USAGE     IS 'Mobile data consumed this month in MB.';
COMMENT ON COLUMN MONTHLY_STATS.MINUTE_USAGE   IS 'Voice minutes consumed this month.';
COMMENT ON COLUMN MONTHLY_STATS.SMS_USAGE      IS 'SMS messages sent this month.';
COMMENT ON COLUMN MONTHLY_STATS.PAYMENT_STATUS IS 'PAID = settled; LATE = overdue but not yet written off; UNPAID = no payment received.';


-- =============================================================
-- STEP 2 – Indexes
-- =============================================================
-- Indexes are created after tables to avoid overhead during
-- bulk CSV imports.  Drop and recreate them after loading data
-- if import performance is a concern.
-- =============================================================

-- CUSTOMERS ───────────────────────────────────────────────────

-- Speeds up tariff-based lookups (queries 1.x, 2.1, 5.x, 6.x)
CREATE INDEX IDX_CUSTOMERS_TARIFF
    ON CUSTOMERS (TARIFF_ID);

-- Speeds up city-distribution GROUP BY queries (3.2, 4.2)
CREATE INDEX IDX_CUSTOMERS_CITY
    ON CUSTOMERS (CITY);

-- Supports ORDER BY / MIN / MAX on signup date (queries 3.x, 1.2)
CREATE INDEX IDX_CUSTOMERS_SIGNUP
    ON CUSTOMERS (SIGNUP_DATE);

-- Composite: tariff + city (useful for 3.2, 4.2 joins)
CREATE INDEX IDX_CUSTOMERS_TARIFF_CITY
    ON CUSTOMERS (TARIFF_ID, CITY);

-- MONTHLY_STATS ───────────────────────────────────────────────

-- Speeds up payment-status filtering (queries 6.x)
CREATE INDEX IDX_STATS_PAYMENT
    ON MONTHLY_STATS (PAYMENT_STATUS);

-- Speeds up usage-percentage calculations (queries 5.x)
CREATE INDEX IDX_STATS_DATA_USAGE
    ON MONTHLY_STATS (DATA_USAGE);


-- =============================================================
-- STEP 3 – Verify creation
-- =============================================================

SELECT
    t.TABLE_NAME,
    t.NUM_ROWS,
    t.STATUS
FROM USER_TABLES t
WHERE t.TABLE_NAME IN ('TARIFFS', 'CUSTOMERS', 'MONTHLY_STATS')
ORDER BY t.TABLE_NAME;

SELECT
    c.TABLE_NAME,
    c.CONSTRAINT_NAME,
    c.CONSTRAINT_TYPE,
    c.STATUS
FROM USER_CONSTRAINTS c
WHERE c.TABLE_NAME IN ('TARIFFS', 'CUSTOMERS', 'MONTHLY_STATS')
ORDER BY c.TABLE_NAME, c.CONSTRAINT_TYPE;

SELECT
    i.TABLE_NAME,
    i.INDEX_NAME,
    i.INDEX_TYPE,
    i.STATUS
FROM USER_INDEXES i
WHERE i.TABLE_NAME IN ('TARIFFS', 'CUSTOMERS', 'MONTHLY_STATS')
ORDER BY i.TABLE_NAME, i.INDEX_NAME;
