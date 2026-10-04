WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V090: payment rules (revival window, amount due) and replay columns

-- Stored on each new payment so a repeated request (same Idempotency-Key) can
-- return exactly what the first one returned. NULL on legacy rows.
ALTER TABLE PAYMENTS ADD (
  NEXT_DUE_AFTER  DATE,
  INSTALMENTS     NUMBER(3),
  CONSTRAINT CK_PAY_INSTALMENTS CHECK (INSTALMENTS > 0)
);

CREATE OR REPLACE PACKAGE PAYMENT_RULES AS
  -- R7: last day a lapsed policy can still be revived (inclusive).
  FUNCTION revival_deadline (p_first_unpaid IN DATE, p_next_due IN DATE) RETURN DATE DETERMINISTIC;

  -- How many instalments a payment made today must cover:
  -- 0 = nothing due yet (PAID), 1 = DUE / IN_GRACE,
  -- N = LAPSED revival: every due date from NEXT_DUE_DATE up to today.
  FUNCTION instalments_due (p_next_due   IN DATE,
                            p_mode       IN VARCHAR2,
                            p_anchor_day IN PLS_INTEGER,
                            p_today      IN DATE) RETURN PLS_INTEGER DETERMINISTIC;

  -- Exact amount to collect today, or NULL when no payment can be taken
  -- (not serviceable, or lapsed beyond the revival window). 0 when PAID.
  FUNCTION amount_due (p_next_due     IN DATE,
                       p_first_unpaid IN DATE,
                       p_mode         IN VARCHAR2,
                       p_anchor_day   IN PLS_INTEGER,
                       p_premium      IN NUMBER,
                       p_today        IN DATE) RETURN NUMBER DETERMINISTIC;
END PAYMENT_RULES;
/

CREATE OR REPLACE PACKAGE BODY PAYMENT_RULES AS

  FUNCTION revival_deadline (p_first_unpaid IN DATE, p_next_due IN DATE) RETURN DATE IS
  BEGIN
    -- Calendar years, not 730 days (leap years). Measured from the first
    -- unpaid due date as R7 says; falls back to the next due date if missing.
    -- ADD_MONTHS is safe here: +24 months lands in the same month, so only
    -- 29 Feb -> 28 Feb can be clipped.
    RETURN ADD_MONTHS(NVL(p_first_unpaid, p_next_due), 24);
  END revival_deadline;

  FUNCTION instalments_due (p_next_due   IN DATE,
                            p_mode       IN VARCHAR2,
                            p_anchor_day IN PLS_INTEGER,
                            p_today      IN DATE) RETURN PLS_INTEGER IS
    n PLS_INTEGER := 0;
  BEGIN
    IF p_next_due IS NULL OR p_mode IS NULL THEN
      RETURN NULL;
    ELSIF p_next_due > p_today + POLICY_RULES.due_window_days THEN
      RETURN 0;                                   -- PAID: nothing due
    ELSIF p_today <= p_next_due + POLICY_RULES.grace_days(p_mode) THEN
      RETURN 1;                                   -- DUE or IN_GRACE
    END IF;
    -- LAPSED: count every due date that has arrived by today.
    WHILE POLICY_RULES.add_periods(p_next_due, p_mode, p_anchor_day, n) <= p_today LOOP
      n := n + 1;
    END LOOP;
    RETURN n;
  END instalments_due;

  FUNCTION amount_due (p_next_due     IN DATE,
                       p_first_unpaid IN DATE,
                       p_mode         IN VARCHAR2,
                       p_anchor_day   IN PLS_INTEGER,
                       p_premium      IN NUMBER,
                       p_today        IN DATE) RETURN NUMBER IS
    v_status VARCHAR2(20) := POLICY_RULES.status(p_next_due, p_mode, p_premium, p_today);
  BEGIN
    IF v_status = 'NOT_SERVICEABLE' THEN
      RETURN NULL;
    ELSIF v_status = 'LAPSED' AND p_today > revival_deadline(p_first_unpaid, p_next_due) THEN
      RETURN NULL;
    END IF;
    RETURN instalments_due(p_next_due, p_mode, p_anchor_day, p_today) * p_premium;
  END amount_due;

END PAYMENT_RULES;
/

SHOW ERRORS PACKAGE PAYMENT_RULES
SHOW ERRORS PACKAGE BODY PAYMENT_RULES
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM USER_ERRORS WHERE NAME = 'PAYMENT_RULES';
  IF n > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'PAYMENT_RULES has compilation errors');
  END IF;
END;
/

-- Same view as V080 plus what the counter screen needs to take a payment.
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
       PAYMENT_RULES.revival_deadline(p.FIRST_UNPAID_DUE_DATE, p.NEXT_DUE_DATE)
                                                                AS REVIVAL_DEADLINE,
       PAYMENT_RULES.instalments_due(p.NEXT_DUE_DATE, p.MODE_CODE, p.DUE_DAY_ANCHOR, clock.today)
                                                                AS INSTALMENTS_DUE,
       PAYMENT_RULES.amount_due(p.NEXT_DUE_DATE, p.FIRST_UNPAID_DUE_DATE, p.MODE_CODE,
                                p.DUE_DAY_ANCHOR, p.PREMIUM, clock.today)
                                                                AS AMOUNT_DUE,
       clock.today                                              AS AS_OF_DATE
FROM POLICIES p
CROSS JOIN clock
LEFT JOIN CUSTOMERS c ON c.CUSTOMER_ID = p.CUSTOMER_ID;

COMMIT;
EXIT
