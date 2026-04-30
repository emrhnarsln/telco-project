-- =============================================================
-- Telco Project - Automatic Database Initialisation Script
-- =============================================================
-- File   : 01_create_tables.sql
-- Runs as: APP_USER (telco schema) on container FIRST BOOT only
-- Engine : Oracle XE 21c  |  Image: gvenzl/oracle-xe
--
-- Execution order is alphabetical; prefix with a number to
-- guarantee ordering when multiple init scripts are present.
--
-- This script is intentionally idempotent:
--   - Tables are dropped safely before recreation so that
--     re-mounting the volume on a fresh container never fails.
--   - All DROP statements silently swallow ORA-00942 (table or
--     view does not exist).
-- =============================================================


-- -------------------------------------------------------------
-- SECTION 0 : Session Setup
-- -------------------------------------------------------------
-- Use a consistent date format for the entire session so that
-- any literal date comparisons behave predictably.
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';
ALTER SESSION SET NLS_LANGUAGE   = 'AMERICAN';


-- -------------------------------------------------------------
-- SECTION 1 : Safe Teardown  (reverse FK order)
-- -------------------------------------------------------------

-- Drop MONTHLY_STATS first (references CUSTOMERS)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE MONTHLY_STATS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;  -- -942 = table does not exist
END;
/

-- Drop CUSTOMERS next (references TARIFFS)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE CUSTOMERS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- Drop TARIFFS last (no outgoing FKs)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE TARIFFS CASCADE CONSTRAINTS PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/


-- -------------------------------------------------------------
-- SECTION 2 : Create TARIFFS
-- -------------------------------------------------------------
-- Parent / lookup table.  Four tariff plans are in use:
--   1 - Genç Dinamik   (data + voice + sms)
--   2 - Kurumsal SMS   (sms-only; data & minute limits are 0)
--   3 - Çalışan GB     (data + voice + sms)
--   4 - Kobiye Destek  (data + voice + sms)
--
-- DATA_LIMIT / MINUTE_LIMIT / SMS_LIMIT use 0 to represent
-- "not included in the package" rather than NULL so that
-- arithmetic comparisons remain straightforward.
-- -------------------------------------------------------------
CREATE TABLE TARIFFS (
    TARIFF_ID       NUMBER(2)       NOT NULL,
    NAME            VARCHAR2(100)   NOT NULL,
    MONTHLY_FEE     NUMBER(10, 2)   NOT NULL,
    DATA_LIMIT      NUMBER(10, 2)   DEFAULT 0   NOT NULL,   -- MB
    MINUTE_LIMIT    NUMBER(6)       DEFAULT 0   NOT NULL,
    SMS_LIMIT       NUMBER(6)       DEFAULT 0   NOT NULL,

    -- ── Constraints ───────────────────────────────────────────
    CONSTRAINT PK_TARIFFS
        PRIMARY KEY (TARIFF_ID),

    CONSTRAINT UQ_TARIFFS_NAME
        UNIQUE (NAME),

    CONSTRAINT CHK_TARIFFS_FEE
        CHECK (MONTHLY_FEE >= 0),

    CONSTRAINT CHK_TARIFFS_DATA
        CHECK (DATA_LIMIT >= 0),

    CONSTRAINT CHK_TARIFFS_MINUTE
        CHECK (MINUTE_LIMIT >= 0),

    CONSTRAINT CHK_TARIFFS_SMS
        CHECK (SMS_LIMIT >= 0)
);


-- -------------------------------------------------------------
-- SECTION 3 : Create CUSTOMERS
-- -------------------------------------------------------------
-- Central entity table.  10 000 customers, IDs 1-10 000.
-- SIGNUP_DATE is stored as DATE (time component is midnight).
-- CITY and NAME contain Turkish characters; the database
-- character set AL32UTF8 handles them transparently in VARCHAR2.
-- -------------------------------------------------------------
CREATE TABLE CUSTOMERS (
    CUSTOMER_ID     NUMBER(6)       NOT NULL,
    NAME            VARCHAR2(100)   NOT NULL,
    CITY            VARCHAR2(100)   NOT NULL,
    SIGNUP_DATE     DATE            NOT NULL,
    TARIFF_ID       NUMBER(2)       NOT NULL,

    -- ── Constraints ───────────────────────────────────────────
    CONSTRAINT PK_CUSTOMERS
        PRIMARY KEY (CUSTOMER_ID),

    CONSTRAINT FK_CUSTOMER_TARIFF
        FOREIGN KEY (TARIFF_ID)
        REFERENCES TARIFFS (TARIFF_ID)
);

-- Indexes on CUSTOMERS
-- IDX_CUSTOMERS_TARIFF   : speeds up JOIN with TARIFFS and tariff-filter queries
-- IDX_CUSTOMERS_CITY     : speeds up GROUP BY / WHERE CITY queries (Q3.2, Q4.2)
-- IDX_CUSTOMERS_SIGNUP   : speeds up MIN/MAX and ORDER BY on SIGNUP_DATE (Q3.1, Q1.2)
CREATE INDEX IDX_CUSTOMERS_TARIFF  ON CUSTOMERS (TARIFF_ID);
CREATE INDEX IDX_CUSTOMERS_CITY    ON CUSTOMERS (CITY);
CREATE INDEX IDX_CUSTOMERS_SIGNUP  ON CUSTOMERS (SIGNUP_DATE);


-- -------------------------------------------------------------
-- SECTION 4 : Create MONTHLY_STATS
-- -------------------------------------------------------------
-- One record per customer per billing month.
-- Due to an insertion error ~50 customers are missing a record
-- for the current month (see queries Q4.1 / Q4.2).
--
-- ID and CUSTOMER_ID carry the same value in the source data;
-- ID is the surrogate PK for the stats row while CUSTOMER_ID
-- is the explicit FK to CUSTOMERS — both columns are retained
-- to match the CSV layout exactly.
--
-- PAYMENT_STATUS is restricted to three permitted values:
--   PAID   – fee collected on time
--   LATE   – fee overdue / in arrears
--   UNPAID – fee not collected at all
--
-- Usage columns are non-negative; a value of 0 for a customer
-- on the "Kurumsal SMS" tariff (DATA_LIMIT = 0, MINUTE_LIMIT = 0)
-- is expected and correct.
-- -------------------------------------------------------------
CREATE TABLE MONTHLY_STATS (
    ID              NUMBER(6)       NOT NULL,
    CUSTOMER_ID     NUMBER(6)       NOT NULL,
    DATA_USAGE      NUMBER(10, 2)   DEFAULT 0   NOT NULL,   -- MB
    MINUTE_USAGE    NUMBER(6)       DEFAULT 0   NOT NULL,
    SMS_USAGE       NUMBER(6)       DEFAULT 0   NOT NULL,
    PAYMENT_STATUS  VARCHAR2(10)    NOT NULL,

    -- ── Constraints ───────────────────────────────────────────
    CONSTRAINT PK_MONTHLY_STATS
        PRIMARY KEY (ID),

    CONSTRAINT FK_STATS_CUSTOMER
        FOREIGN KEY (CUSTOMER_ID)
        REFERENCES CUSTOMERS (CUSTOMER_ID),

    -- One monthly record per customer at most
    CONSTRAINT UQ_STATS_CUSTOMER
        UNIQUE (CUSTOMER_ID),

    CONSTRAINT CHK_PAYMENT_STATUS
        CHECK (PAYMENT_STATUS IN ('PAID', 'LATE', 'UNPAID')),

    CONSTRAINT CHK_STATS_DATA
        CHECK (DATA_USAGE >= 0),

    CONSTRAINT CHK_STATS_MINUTE
        CHECK (MINUTE_USAGE >= 0),

    CONSTRAINT CHK_STATS_SMS
        CHECK (SMS_USAGE >= 0)
);

-- Indexes on MONTHLY_STATS
-- IDX_STATS_PAYMENT  : speeds up payment-status filter and GROUP BY queries (Q6.1, Q6.2)
-- IDX_STATS_CUSTOMER is covered by the UQ_STATS_CUSTOMER unique constraint index
CREATE INDEX IDX_STATS_PAYMENT ON MONTHLY_STATS (PAYMENT_STATUS);


-- -------------------------------------------------------------
-- SECTION 5 : Verification  (output visible in container logs)
-- -------------------------------------------------------------
-- Print a summary so the Docker logs clearly confirm success.
SET SERVEROUTPUT ON SIZE UNLIMITED;

BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('==============================================');
    DBMS_OUTPUT.PUT_LINE(' Telco Schema Initialisation — COMPLETE');
    DBMS_OUTPUT.PUT_LINE('==============================================');
    DBMS_OUTPUT.PUT_LINE(' Tables created:');
    DBMS_OUTPUT.PUT_LINE('   [OK] TARIFFS');
    DBMS_OUTPUT.PUT_LINE('   [OK] CUSTOMERS');
    DBMS_OUTPUT.PUT_LINE('   [OK] MONTHLY_STATS');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE(' Next step: import CSV data via DBeaver.');
    DBMS_OUTPUT.PUT_LINE(' See docs/SETUP.md for step-by-step instructions.');
    DBMS_OUTPUT.PUT_LINE('==============================================');
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- End of script
