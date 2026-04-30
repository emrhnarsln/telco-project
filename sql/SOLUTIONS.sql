-- =============================================================
-- SOLUTIONS.sql
-- Project  : Telco Project – i2i Systems
-- Database : Oracle XE 21c
-- Schema   : telco  (APP_USER)
-- =============================================================
-- Every query is preceded by a multi-line comment of at least
-- three sentences explaining the approach, the tables/columns
-- involved, and any edge cases that were considered.
--
-- Run the session setup block first so that DATE comparisons
-- and string handling behave consistently across environments.
-- =============================================================

-- Session setup (run once before executing any query below)
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';
ALTER SESSION SET NLS_LANGUAGE    = 'AMERICAN';


-- =============================================================
-- SECTION 1 : Tariff-Based Customer Queries
-- =============================================================


-- -------------------------------------------------------------
-- 1.1  List customers subscribed to the 'Kobiye Destek' tariff
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We join CUSTOMERS to TARIFFS on TARIFF_ID and filter by
 *   the tariff NAME rather than hard-coding the TARIFF_ID value
 *   (which is 4 in the current dataset). Using the name makes
 *   the query robust to potential ID changes in the future and
 *   documents intent more clearly for any reader.
 *
 *   The result set includes CUSTOMER_ID, NAME, CITY, and
 *   SIGNUP_DATE so that the output is self-contained and
 *   useful for downstream reporting without needing a second
 *   lookup.
 *
 *   Rows are ordered by SIGNUP_DATE ascending so the output
 *   naturally tells the chronological story of when each
 *   subscriber joined this particular tariff plan.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    c.SIGNUP_DATE,
    t.NAME          AS TARIFF_NAME,
    t.MONTHLY_FEE
FROM CUSTOMERS c
JOIN TARIFFS   t ON c.TARIFF_ID = t.TARIFF_ID
WHERE t.NAME = 'Kobiye Destek'
ORDER BY c.SIGNUP_DATE ASC;


-- -------------------------------------------------------------
-- 1.2  Find the newest customer subscribed to 'Kobiye Destek'
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We reuse the same join from 1.1 and narrow the result to
 *   the single row whose SIGNUP_DATE equals the MAX signup date
 *   among all 'Kobiye Destek' subscribers. Using a correlated
 *   scalar sub-query for the maximum date is clean, readable,
 *   and avoids the ROWNUM / FETCH tricks that can silently
 *   return only one row even when there are ties.
 *
 *   If two customers share the exact same latest SIGNUP_DATE,
 *   this query returns both rows, preserving data integrity
 *   and making tie-breaking an explicit downstream decision
 *   rather than hiding it inside the query logic.
 *
 *   An alternative implementation using ROW_NUMBER() OVER
 *   (ORDER BY SIGNUP_DATE DESC) is shown as a comment at the
 *   bottom of this block for reference.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    c.SIGNUP_DATE,
    t.NAME          AS TARIFF_NAME
FROM CUSTOMERS c
JOIN TARIFFS   t ON c.TARIFF_ID = t.TARIFF_ID
WHERE t.NAME = 'Kobiye Destek'
  AND c.SIGNUP_DATE = (
          SELECT MAX(c2.SIGNUP_DATE)
          FROM   CUSTOMERS c2
          JOIN   TARIFFS   t2 ON c2.TARIFF_ID = t2.TARIFF_ID
          WHERE  t2.NAME = 'Kobiye Destek'
      );

-- Alternative using analytic ROW_NUMBER (also valid):
-- SELECT CUSTOMER_ID, NAME, CITY, SIGNUP_DATE, TARIFF_NAME
-- FROM (
--     SELECT c.CUSTOMER_ID, c.NAME, c.CITY, c.SIGNUP_DATE,
--            t.NAME AS TARIFF_NAME,
--            ROW_NUMBER() OVER (ORDER BY c.SIGNUP_DATE DESC) AS RN
--     FROM   CUSTOMERS c
--     JOIN   TARIFFS   t ON c.TARIFF_ID = t.TARIFF_ID
--     WHERE  t.NAME = 'Kobiye Destek'
-- )
-- WHERE RN = 1;


-- =============================================================
-- SECTION 2 : Tariff Distribution
-- =============================================================


-- -------------------------------------------------------------
-- 2.1  Distribution of tariffs among customers
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We aggregate CUSTOMERS grouped by TARIFF_ID and join the
 *   result with TARIFFS to display the human-readable tariff
 *   name alongside the raw count. A window function
 *   (SUM ... OVER ()) computes the grand total once and avoids
 *   a second full-table scan just to calculate the percentage.
 *
 *   The percentage column (PCTG) is rounded to two decimal
 *   places and labelled clearly so the output can be pasted
 *   directly into a report without further transformation.
 *
 *   The MONTHLY_FEE column is included so readers can
 *   immediately correlate subscriber volume with the revenue
 *   contribution of each plan, providing business context
 *   alongside the raw distribution figures.
 */
SELECT
    t.TARIFF_ID,
    t.NAME                                                      AS TARIFF_NAME,
    t.MONTHLY_FEE,
    COUNT(c.CUSTOMER_ID)                                        AS CUSTOMER_COUNT,
    ROUND(
        COUNT(c.CUSTOMER_ID) * 100
        / SUM(COUNT(c.CUSTOMER_ID)) OVER (),
        2
    )                                                           AS PERCENTAGE
FROM CUSTOMERS c
JOIN TARIFFS   t ON c.TARIFF_ID = t.TARIFF_ID
GROUP BY t.TARIFF_ID, t.NAME, t.MONTHLY_FEE
ORDER BY CUSTOMER_COUNT DESC;


-- =============================================================
-- SECTION 3 : Customer Signup Analysis
-- =============================================================


-- -------------------------------------------------------------
-- 3.1  Identify the earliest customers to sign up
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   Earliest is determined by the minimum value of SIGNUP_DATE,
 *   NOT by the lowest CUSTOMER_ID. As the hint in the project
 *   specification warns, the source system assigned IDs
 *   independently of when customers actually signed up, so
 *   filtering by MIN(CUSTOMER_ID) would silently return wrong
 *   results. The correct anchor is MIN(SIGNUP_DATE).
 *
 *   The inner sub-query materialises the single earliest date
 *   and the outer query returns every customer whose
 *   SIGNUP_DATE matches that date, ensuring that all ties
 *   (multiple customers who signed up on the very same day)
 *   are visible rather than arbitrarily dropped.
 *
 *   Tariff information is included via a JOIN so that the
 *   output immediately shows which plan each early adopter
 *   chose, which can inform retention or loyalty decisions.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    c.SIGNUP_DATE,
    t.NAME  AS TARIFF_NAME
FROM CUSTOMERS c
JOIN TARIFFS   t ON c.TARIFF_ID = t.TARIFF_ID
WHERE c.SIGNUP_DATE = (SELECT MIN(SIGNUP_DATE) FROM CUSTOMERS)
ORDER BY c.CUSTOMER_ID;


-- -------------------------------------------------------------
-- 3.2  Distribution of earliest customers across cities
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We apply the same MIN(SIGNUP_DATE) anchor from query 3.1
 *   and then aggregate by CITY using GROUP BY. Repeating the
 *   sub-query (rather than creating a temporary table) keeps
 *   the solution self-contained and executable in a single
 *   statement without any session-level objects.
 *
 *   The COUNT(*) alias CUSTOMER_COUNT makes the column label
 *   unambiguous in exported result sets and BI tools. Ordering
 *   by count descending puts the most-represented cities at
 *   the top, which is more useful for a quick visual scan.
 *
 *   If the earliest signup date has only one customer, the
 *   result will contain a single row with a count of 1; this
 *   is a valid and expected degenerate case that the query
 *   handles gracefully without any special-casing.
 */
SELECT
    c.CITY,
    COUNT(*)    AS CUSTOMER_COUNT
FROM CUSTOMERS c
WHERE c.SIGNUP_DATE = (SELECT MIN(SIGNUP_DATE) FROM CUSTOMERS)
GROUP BY c.CITY
ORDER BY CUSTOMER_COUNT DESC, c.CITY ASC;


-- =============================================================
-- SECTION 4 : Missing Monthly Records
-- =============================================================


-- -------------------------------------------------------------
-- 4.1  Identify customer IDs whose monthly record is missing
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   The MONTHLY_STATS table should contain exactly one row per
 *   customer for the current billing month, but an insertion
 *   error left some customers without a record. We find these
 *   by performing a LEFT JOIN from CUSTOMERS to MONTHLY_STATS
 *   on CUSTOMER_ID and keeping only the rows where the right-
 *   hand side produced no match (ms.CUSTOMER_ID IS NULL).
 *
 *   A LEFT JOIN is preferred over NOT IN for correctness: if
 *   MONTHLY_STATS.CUSTOMER_ID ever contained a NULL value,
 *   NOT IN would return zero rows due to three-valued logic,
 *   whereas LEFT JOIN + IS NULL handles NULLs safely.
 *   NOT EXISTS would also be correct, but the JOIN approach
 *   tends to be more readable for developers unfamiliar with
 *   correlated sub-queries.
 *
 *   The query also includes NAME and CITY from CUSTOMERS so
 *   that the operations team can immediately identify and
 *   contact the affected subscribers without a follow-up join.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    c.SIGNUP_DATE,
    t.NAME  AS TARIFF_NAME,
    t.MONTHLY_FEE
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
LEFT JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE ms.CUSTOMER_ID IS NULL
ORDER BY c.CUSTOMER_ID;


-- -------------------------------------------------------------
-- 4.2  Distribution of missing customers across cities
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We extend the anti-join logic from query 4.1 and add a
 *   GROUP BY CITY to count how many missing customers belong
 *   to each city. This helps the operations team prioritise
 *   regions where the insertion error had the highest impact.
 *
 *   Including TARIFF_MISSING_COUNT as a second breakdown
 *   (via a nested sub-query or inline view) would be possible
 *   but is deliberately omitted here to keep the output
 *   focused on the geographic distribution as requested.
 *   A follow-up query (Section 4.2b below) shows that
 *   additional breakdown per tariff if needed.
 *
 *   Results are ordered by CUSTOMER_COUNT descending so the
 *   cities with the largest number of affected customers
 *   appear first, enabling immediate triage by the data
 *   engineering team.
 */
SELECT
    c.CITY,
    COUNT(*)    AS CUSTOMER_COUNT
FROM CUSTOMERS     c
LEFT JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE ms.CUSTOMER_ID IS NULL
GROUP BY c.CITY
ORDER BY CUSTOMER_COUNT DESC, c.CITY ASC;

-- Bonus breakdown: missing customers per city AND tariff
SELECT
    c.CITY,
    t.NAME      AS TARIFF_NAME,
    COUNT(*)    AS CUSTOMER_COUNT
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
LEFT JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE ms.CUSTOMER_ID IS NULL
GROUP BY c.CITY, t.NAME
ORDER BY c.CITY ASC, CUSTOMER_COUNT DESC;


-- =============================================================
-- SECTION 5 : Usage Analysis
-- =============================================================


-- -------------------------------------------------------------
-- 5.1  Customers who have used at least 75% of their data limit
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   The comparison DATA_USAGE / DATA_LIMIT >= 0.75 would cause
 *   an ORA-01476 (divisor is zero) for the 'Kurumsal SMS'
 *   tariff, which carries DATA_LIMIT = 0 (no data package
 *   included). We guard against this with the predicate
 *   t.DATA_LIMIT > 0, which excludes those customers before
 *   the division is evaluated. Oracle evaluates WHERE conditions
 *   left-to-right in most execution plans, but wrapping in
 *   a CASE or using NULLIF is equally valid and shown as an
 *   alternative comment below.
 *
 *   The DATA_USAGE_PCT column shows the exact consumption
 *   ratio rounded to two decimal places, making it easy to
 *   sort customers from most-to-least critical (ORDER BY
 *   DATA_USAGE_PCT DESC) and to filter further (e.g. > 90%)
 *   without rewriting the query.
 *
 *   Only customers who already have a MONTHLY_STATS record are
 *   included (INNER JOIN); customers with missing records
 *   (identified in Section 4) are intentionally excluded
 *   because their usage values are unknown and should not
 *   be assumed to be zero.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    t.NAME                                                AS TARIFF_NAME,
    t.DATA_LIMIT,
    ms.DATA_USAGE,
    ROUND(ms.DATA_USAGE / t.DATA_LIMIT * 100, 2)         AS DATA_USAGE_PCT
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE t.DATA_LIMIT > 0                              -- exclude zero-limit tariffs
  AND ms.DATA_USAGE >= t.DATA_LIMIT * 0.75
ORDER BY DATA_USAGE_PCT DESC;

-- Alternative using NULLIF to handle division by zero inline:
-- SELECT ...
--    ROUND(ms.DATA_USAGE / NULLIF(t.DATA_LIMIT, 0) * 100, 2) AS DATA_USAGE_PCT
-- FROM ...
-- WHERE ms.DATA_USAGE / NULLIF(t.DATA_LIMIT, 0) >= 0.75;


-- -------------------------------------------------------------
-- 5.2  Customers who exhausted ALL of their package limits
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   "Exhausted" means the customer's usage meets or exceeds
 *   every resource limit that is actually part of their tariff.
 *   A limit of 0 (zero) signals that the resource is NOT
 *   included in the package (e.g. Kurumsal SMS has DATA = 0
 *   and MINUTE = 0), so we treat a zero limit as automatically
 *   satisfied using the pattern: (LIMIT = 0 OR USAGE >= LIMIT).
 *   This avoids the division-by-zero problem and correctly
 *   allows a Kurumsal SMS customer to appear if they exhaust
 *   their 10 000 SMS allowance, without requiring them to
 *   also exhaust data or minutes that they never had.
 *
 *   For tariffs that do include all three resources (Genç
 *   Dinamik, Çalışan GB, Kobiye Destek), all three conditions
 *   must simultaneously be true (AND logic), so only the most
 *   heavy users of every resource type qualify.
 *
 *   The PAYMENT_STATUS column is included to highlight whether
 *   customers who have used everything they paid for have also
 *   settled their bill — a useful cross-reference for the
 *   collections and retention teams.
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    t.NAME              AS TARIFF_NAME,
    ms.DATA_USAGE,      t.DATA_LIMIT,
    ms.MINUTE_USAGE,    t.MINUTE_LIMIT,
    ms.SMS_USAGE,       t.SMS_LIMIT,
    ms.PAYMENT_STATUS
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE
    -- Data: if no data package, condition is trivially satisfied
    (t.DATA_LIMIT   = 0 OR ms.DATA_USAGE   >= t.DATA_LIMIT)
    -- Voice: same zero-limit guard
AND (t.MINUTE_LIMIT = 0 OR ms.MINUTE_USAGE >= t.MINUTE_LIMIT)
    -- SMS: same zero-limit guard
AND (t.SMS_LIMIT    = 0 OR ms.SMS_USAGE    >= t.SMS_LIMIT)
ORDER BY t.NAME, c.CUSTOMER_ID;


-- =============================================================
-- SECTION 6 : Payment Analysis
-- =============================================================


-- -------------------------------------------------------------
-- 6.1  Customers who have unpaid fees
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   Payment records carry three possible statuses: PAID, LATE,
 *   and UNPAID. "UNPAID" represents fees where no payment
 *   whatsoever has been received for the current month. "LATE"
 *   represents fees that are overdue — payment was expected
 *   but has not arrived on time. Both statuses represent
 *   outstanding balances from a collections perspective, so
 *   this query returns customers in EITHER state using an IN
 *   predicate, with a clear column alias distinguishing the
 *   specific status.
 *
 *   The MONTHLY_FEE from the TARIFFS table is joined in so
 *   that the finance team can immediately see the monetary
 *   value at risk for each outstanding account, enabling
 *   prioritisation by fee amount rather than just by status.
 *
 *   Customers who do not have a MONTHLY_STATS record at all
 *   (the missing-record group from Section 4) are excluded
 *   by the INNER JOIN; their payment status is unknown, so
 *   including them would be speculative. A separate process
 *   should handle their missing records first (see Q4.1).
 */
SELECT
    c.CUSTOMER_ID,
    c.NAME,
    c.CITY,
    t.NAME              AS TARIFF_NAME,
    t.MONTHLY_FEE,
    ms.PAYMENT_STATUS
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE ms.PAYMENT_STATUS IN ('UNPAID', 'LATE')
ORDER BY ms.PAYMENT_STATUS, t.MONTHLY_FEE DESC, c.CUSTOMER_ID;

-- If strictly only UNPAID (no payment received at all) is required:
-- WHERE ms.PAYMENT_STATUS = 'UNPAID'

-- Summary count by status:
SELECT
    ms.PAYMENT_STATUS,
    COUNT(*)        AS CUSTOMER_COUNT,
    SUM(t.MONTHLY_FEE)                                      AS TOTAL_REVENUE_AT_RISK,
    ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 2)        AS PERCENTAGE
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
WHERE ms.PAYMENT_STATUS IN ('UNPAID', 'LATE')
GROUP BY ms.PAYMENT_STATUS
ORDER BY CUSTOMER_COUNT DESC;


-- -------------------------------------------------------------
-- 6.2  Distribution of all payment statuses across tariffs
-- -------------------------------------------------------------
/*
 * APPROACH:
 *   We need both the row count and the within-tariff percentage
 *   for each (tariff, status) combination. The analytic
 *   SUM(COUNT(*)) OVER (PARTITION BY t.NAME) computes the
 *   total for each tariff in a single pass without a self-join
 *   or a second GROUP BY level, keeping the query both
 *   efficient and easy to read.
 *
 *   The PIVOT approach (Oracle 11g+) was considered but
 *   rejected here because the number of distinct status values
 *   may change in future data loads, and a hard-coded PIVOT
 *   would silently drop any new status values. The GROUP BY
 *   approach is therefore more maintainable.
 *
 *   Results are ordered by TARIFF_NAME first and then by
 *   CUSTOMER_COUNT descending within each tariff, so the
 *   dominant payment behaviour for each plan is immediately
 *   visible at the top of each group.
 */
SELECT
    t.NAME                                                      AS TARIFF_NAME,
    t.MONTHLY_FEE,
    ms.PAYMENT_STATUS,
    COUNT(*)                                                    AS CUSTOMER_COUNT,
    ROUND(
        COUNT(*) * 100
        / SUM(COUNT(*)) OVER (PARTITION BY t.NAME),
        2
    )                                                           AS PCT_WITHIN_TARIFF,
    ROUND(
        COUNT(*) * 100
        / SUM(COUNT(*)) OVER (),
        2
    )                                                           AS PCT_OF_ALL_CUSTOMERS
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
GROUP BY t.NAME, t.MONTHLY_FEE, ms.PAYMENT_STATUS
ORDER BY t.NAME ASC, CUSTOMER_COUNT DESC;

-- Cross-tab summary: total per tariff
SELECT
    t.NAME                  AS TARIFF_NAME,
    COUNT(ms.ID)            AS TOTAL_WITH_STATS,
    SUM(CASE WHEN ms.PAYMENT_STATUS = 'PAID'   THEN 1 ELSE 0 END) AS PAID_COUNT,
    SUM(CASE WHEN ms.PAYMENT_STATUS = 'LATE'   THEN 1 ELSE 0 END) AS LATE_COUNT,
    SUM(CASE WHEN ms.PAYMENT_STATUS = 'UNPAID' THEN 1 ELSE 0 END) AS UNPAID_COUNT,
    ROUND(
        SUM(CASE WHEN ms.PAYMENT_STATUS = 'PAID' THEN 1 ELSE 0 END) * 100
        / NULLIF(COUNT(ms.ID), 0),
        1
    )                       AS PAID_PCT
FROM CUSTOMERS     c
JOIN TARIFFS       t  ON c.TARIFF_ID   = t.TARIFF_ID
LEFT JOIN MONTHLY_STATS ms ON c.CUSTOMER_ID = ms.CUSTOMER_ID
GROUP BY t.NAME
ORDER BY t.NAME;


-- =============================================================
-- END OF SOLUTIONS.sql
-- =============================================================
