WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V080: derived-status view (replaces the stub)

-- R4: status is calculated every time it is read, never stored, and
-- LEGACY_STATUS is not used. All rules come from POLICY_RULES.
-- LEFT JOIN: policy 5021 has no customer row but must still be listed.
CREATE OR REPLACE VIEW V_POLICY_STATUS AS
WITH clock AS (
  SELECT POLICY_RULES.today_ist AS today FROM dual
)
SELECT p.POLICY_ID,
       p.POLICY_NO,
       p.CUSTOMER_ID,
       c.FULL_NAME                                              AS CUSTOMER_NAME,
       p.PLAN_NAME,
       p.MODE_CODE,
       p.PREMIUM,
       p.SUM_ASSURED,
       p.COMMENCEMENT_DATE,
       p.NEXT_DUE_DATE,
       p.FIRST_UNPAID_DUE_DATE,
       p.NEXT_DUE_DATE + POLICY_RULES.grace_days(p.MODE_CODE)   AS GRACE_END_DATE,
       POLICY_RULES.status(p.NEXT_DUE_DATE, p.MODE_CODE, p.PREMIUM, clock.today)
                                                                AS DERIVED_STATUS,
       clock.today                                              AS AS_OF_DATE
FROM POLICIES p
CROSS JOIN clock
LEFT JOIN CUSTOMERS c ON c.CUSTOMER_ID = p.CUSTOMER_ID;

EXIT
