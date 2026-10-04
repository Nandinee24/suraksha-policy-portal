-- Data profiling of the legacy seed. Read-only: changes nothing.
-- Run as SURAKSHA. Each block proves one assumption the legacy data breaks.
SET LINESIZE 220
SET PAGESIZE 200
SET FEEDBACK ON
COLUMN mode_raw   FORMAT A16
COLUMN shape      FORMAT A20
COLUMN raw_amount FORMAT A18
COLUMN policy_no  FORMAT A18
COLUMN full_name  FORMAT A28
COLUMN pan        FORMAT A14
COLUMN idem_key   FORMAT A22
COLUMN legacy_status FORMAT A14

PROMPT === 1. Row counts (expect 155 / 194 / 472)
SELECT (SELECT COUNT(*) FROM CUSTOMERS) customers,
       (SELECT COUNT(*) FROM POLICIES)  policies,
       (SELECT COUNT(*) FROM PAYMENTS)  payments
FROM dual;

PROMPT === 2. Premium mode: every spelling in use (brackets show stray spaces)
SELECT '[' || PREMIUM_MODE || ']' AS mode_raw, COUNT(*) AS n
FROM POLICIES
GROUP BY PREMIUM_MODE
ORDER BY n DESC;

PROMPT === 3. Premium amount: formats in use (every digit shown as 9)
SELECT REGEXP_REPLACE(NVL(PREMIUM_AMOUNT, '<NULL>'), '[0-9]', '9') AS shape, COUNT(*) AS n
FROM POLICIES
GROUP BY REGEXP_REPLACE(NVL(PREMIUM_AMOUNT, '<NULL>'), '[0-9]', '9')
ORDER BY n DESC;

PROMPT === 4. Premiums that are missing, zero or negative after parsing
SELECT POLICY_ID, '[' || PREMIUM_AMOUNT || ']' AS raw_amount,
       TO_NUMBER(REPLACE(REPLACE(REGEXP_REPLACE(UPPER(TRIM(PREMIUM_AMOUNT)), '^(RS\.?|INR)\s*', ''), ',', ''), ' ', '')
                 DEFAULT NULL ON CONVERSION ERROR) AS parsed
FROM POLICIES
WHERE NVL(TO_NUMBER(REPLACE(REPLACE(REGEXP_REPLACE(UPPER(TRIM(PREMIUM_AMOUNT)), '^(RS\.?|INR)\s*', ''), ',', ''), ' ', '')
                    DEFAULT NULL ON CONVERSION ERROR), 0) <= 0;

PROMPT === 5a. Policies whose customer does not exist (will break the FK)
SELECT p.POLICY_ID, p.POLICY_NO, p.CUSTOMER_ID
FROM POLICIES p
WHERE NOT EXISTS (SELECT 1 FROM CUSTOMERS c WHERE c.CUSTOMER_ID = p.CUSTOMER_ID);

PROMPT === 5b. Payments whose policy does not exist (will break the FK)
SELECT y.PAYMENT_ID, y.POLICY_ID, y.AMOUNT, y.IDEMPOTENCY_KEY AS idem_key
FROM PAYMENTS y
WHERE NOT EXISTS (SELECT 1 FROM POLICIES p WHERE p.POLICY_ID = y.POLICY_ID);

PROMPT === 6. Idempotency key used more than once (R8 already violated)
SELECT PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY AS idem_key, CHANNEL
FROM PAYMENTS
WHERE IDEMPOTENCY_KEY IN (SELECT IDEMPOTENCY_KEY FROM PAYMENTS GROUP BY IDEMPOTENCY_KEY HAVING COUNT(*) > 1)
ORDER BY PAID_AT;

PROMPT === 7. Policy number duplicated when case/spaces are ignored
SELECT POLICY_ID, '[' || POLICY_NO || ']' AS policy_no, CUSTOMER_ID, COMMENCEMENT_DATE
FROM POLICIES
WHERE UPPER(TRIM(POLICY_NO)) IN (SELECT UPPER(TRIM(POLICY_NO)) FROM POLICIES
                                GROUP BY UPPER(TRIM(POLICY_NO)) HAVING COUNT(*) > 1);

PROMPT === 8. Same instalment paid more than once
SELECT POLICY_ID, COVERS_DUE_DATE, COUNT(*) AS n
FROM PAYMENTS
GROUP BY POLICY_ID, COVERS_DUE_DATE
HAVING COUNT(*) > 1;

PROMPT === 9. Customers: duplicate PAN (normalised), bad PAN format, messy names
SELECT CUSTOMER_ID, '[' || FULL_NAME || ']' AS full_name, '[' || PAN || ']' AS pan
FROM CUSTOMERS
WHERE UPPER(TRIM(PAN)) IN (SELECT UPPER(TRIM(PAN)) FROM CUSTOMERS GROUP BY UPPER(TRIM(PAN)) HAVING COUNT(*) > 1)
   OR NOT REGEXP_LIKE(PAN, '^[A-Z]{5}[0-9]{4}[A-Z]$')
   OR FULL_NAME <> TRIM(FULL_NAME)
   OR REGEXP_LIKE(FULL_NAME, '\s{2,}')
   OR FULL_NAME = UPPER(FULL_NAME)
   OR NOT REGEXP_LIKE(FULL_NAME, '^[A-Za-z ]+$');

PROMPT === 10. Impossible or missing dates (days relative to load date)
SELECT POLICY_ID, LEGACY_STATUS,
       NEXT_DUE_DATE - TRUNC(SYSDATE)         AS next_due_offset,
       FIRST_UNPAID_DUE_DATE - TRUNC(SYSDATE) AS first_unpaid_offset
FROM POLICIES
WHERE NEXT_DUE_DATE IS NULL
   OR FIRST_UNPAID_DUE_DATE > NEXT_DUE_DATE;

PROMPT === 11. LEGACY_STATUS values (why R4 says never to trust it)
SELECT '[' || LEGACY_STATUS || ']' AS legacy_status, COUNT(*) AS n,
       SUM(CASE WHEN NEXT_DUE_DATE < TRUNC(SYSDATE) - 30 THEN 1 ELSE 0 END) AS overdue_over_30_days
FROM POLICIES
GROUP BY LEGACY_STATUS;

PROMPT === 12. Payments that do not equal the policy premium (R5 already violated)
SELECT y.PAYMENT_ID, y.POLICY_ID, y.AMOUNT, p.PREMIUM_AMOUNT AS raw_amount, y.CHANNEL
FROM PAYMENTS y
JOIN POLICIES p ON p.POLICY_ID = y.POLICY_ID
WHERE y.AMOUNT <> NVL(TO_NUMBER(REPLACE(REPLACE(REGEXP_REPLACE(UPPER(TRIM(p.PREMIUM_AMOUNT)), '^(RS\.?|INR)\s*', ''), ',', ''), ' ', '')
                                DEFAULT NULL ON CONVERSION ERROR), -1);

PROMPT === 13. Payments whose IST date differs from their UTC date (R3 timezone cases)
SELECT PAYMENT_ID, POLICY_ID, PAID_AT AS paid_at_utc,
       CAST(FROM_TZ(PAID_AT, 'UTC') AT TIME ZONE 'Asia/Kolkata' AS DATE) AS paid_at_ist,
       COVERS_DUE_DATE - TRUNC(SYSDATE) AS covers_offset
FROM PAYMENTS
WHERE TRUNC(CAST(FROM_TZ(PAID_AT, 'UTC') AT TIME ZONE 'Asia/Kolkata' AS DATE)) <> TRUNC(PAID_AT);

EXIT