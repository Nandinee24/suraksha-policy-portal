WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V070: business-rule package (IST today, grace, month maths, status)

-- Test clock. One row. FROZEN_TODAY is NULL in normal use; tests set it to
-- pretend "today" is a given date. A table (not a package variable) so that
-- recompiling the package never breaks pooled sessions (ORA-04068).
CREATE TABLE APP_CLOCK (
  ID            NUMBER(1) DEFAULT 1 NOT NULL,
  FROZEN_TODAY  DATE,
  CONSTRAINT PK_APP_CLOCK PRIMARY KEY (ID),
  CONSTRAINT CK_APP_CLOCK_ONE_ROW CHECK (ID = 1)
);
INSERT INTO APP_CLOCK (ID, FROZEN_TODAY) VALUES (1, NULL);

-- R6 month maths needs each policy's real due day. Example: a policy due on
-- the 31st goes 31 Jan -> 28 Feb -> 31 Mar; without remembering "31" it would
-- drift to 28 Mar. Taken from the current next due date; a date on the last
-- day of its month means a month-end policy (31).
-- Limitation: a policy truly due on the 30th that currently sits on 28 Feb
-- looks like month-end. The legacy data has no history to tell them apart.
ALTER TABLE POLICIES ADD (DUE_DAY_ANCHOR NUMBER(2));
UPDATE POLICIES
SET DUE_DAY_ANCHOR = CASE
    WHEN NEXT_DUE_DATE IS NULL                  THEN NULL
    WHEN NEXT_DUE_DATE = LAST_DAY(NEXT_DUE_DATE) THEN 31
    ELSE EXTRACT(DAY FROM NEXT_DUE_DATE)
  END;
ALTER TABLE POLICIES ADD CONSTRAINT CK_POL_DUE_DAY_ANCHOR CHECK (DUE_DAY_ANCHOR BETWEEN 1 AND 31);

COMMIT;

CREATE OR REPLACE PACKAGE POLICY_RULES AS
  -- R3: the business date in IST (never SYSDATE: the server runs in UTC).
  FUNCTION today_ist RETURN DATE;

  -- R4: "due" means the next due date is within this many days.
  FUNCTION due_window_days RETURN PLS_INTEGER DETERMINISTIC;

  -- R2: 15 days for Monthly, 30 for Yearly/Half-yearly/Quarterly.
  FUNCTION grace_days (p_mode IN VARCHAR2) RETURN PLS_INTEGER DETERMINISTIC;

  -- R1: length of one mode period in months.
  FUNCTION months_in (p_mode IN VARCHAR2) RETURN PLS_INTEGER DETERMINISTIC;

  -- R6: move a due date forward by p_n mode periods, keeping the anchor day
  -- (clipped to the month's last day).
  FUNCTION add_periods (p_date       IN DATE,
                        p_mode       IN VARCHAR2,
                        p_anchor_day IN PLS_INTEGER,
                        p_n          IN PLS_INTEGER DEFAULT 1) RETURN DATE DETERMINISTIC;

  -- R4: PAID / DUE / IN_GRACE / LAPSED, or NOT_SERVICEABLE when the policy
  -- has no valid mode, premium or due date.
  FUNCTION status (p_next_due IN DATE,
                   p_mode     IN VARCHAR2,
                   p_premium  IN NUMBER,
                   p_today    IN DATE) RETURN VARCHAR2 DETERMINISTIC;
END POLICY_RULES;
/

CREATE OR REPLACE PACKAGE BODY POLICY_RULES AS

  FUNCTION today_ist RETURN DATE IS
    v_frozen DATE;
  BEGIN
    SELECT FROZEN_TODAY INTO v_frozen FROM APP_CLOCK WHERE ID = 1;
    RETURN NVL(v_frozen, TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata' AS DATE)));
  END today_ist;

  FUNCTION due_window_days RETURN PLS_INTEGER IS
  BEGIN
    RETURN 30;
  END due_window_days;

  FUNCTION grace_days (p_mode IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    RETURN CASE p_mode
             WHEN 'M' THEN 15
             WHEN 'Q' THEN 30
             WHEN 'H' THEN 30
             WHEN 'Y' THEN 30
           END;
  END grace_days;

  FUNCTION months_in (p_mode IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    RETURN CASE p_mode
             WHEN 'M' THEN 1
             WHEN 'Q' THEN 3
             WHEN 'H' THEN 6
             WHEN 'Y' THEN 12
           END;
  END months_in;

  FUNCTION add_periods (p_date       IN DATE,
                        p_mode       IN VARCHAR2,
                        p_anchor_day IN PLS_INTEGER,
                        p_n          IN PLS_INTEGER DEFAULT 1) RETURN DATE IS
    v_first_of_month DATE;
  BEGIN
    -- Go to the 1st of the target month (the 1st always exists), then add the
    -- anchor day, but never past that month's last day.
    -- Not "+ INTERVAL '1' MONTH": raises ORA-01839 on 31 Jan.
    -- Not plain ADD_MONTHS: 30 Apr + 1 gives 31 May, 28 Feb + 1 gives 31 Mar.
    v_first_of_month := ADD_MONTHS(TRUNC(p_date, 'MM'), months_in(p_mode) * p_n);
    RETURN LEAST(v_first_of_month + (NVL(p_anchor_day, EXTRACT(DAY FROM p_date)) - 1),
                 LAST_DAY(v_first_of_month));
  END add_periods;

  FUNCTION status (p_next_due IN DATE,
                   p_mode     IN VARCHAR2,
                   p_premium  IN NUMBER,
                   p_today    IN DATE) RETURN VARCHAR2 IS
  BEGIN
    IF p_next_due IS NULL OR p_mode IS NULL OR p_premium IS NULL THEN
      RETURN 'NOT_SERVICEABLE';
    ELSIF p_next_due > p_today + due_window_days THEN
      RETURN 'PAID';        -- more than 30 days away
    ELSIF p_next_due >= p_today THEN
      RETURN 'DUE';         -- within 30 days, not yet past (due today = DUE)
    ELSIF p_today <= p_next_due + grace_days(p_mode) THEN
      RETURN 'IN_GRACE';    -- last day of grace still counts (R3)
    ELSE
      RETURN 'LAPSED';
    END IF;
  END status;

END POLICY_RULES;
/

SHOW ERRORS PACKAGE POLICY_RULES
SHOW ERRORS PACKAGE BODY POLICY_RULES

-- SQL*Plus only warns on compilation errors; turn them into a real failure.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM USER_ERRORS WHERE NAME = 'POLICY_RULES';
  IF n > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'POLICY_RULES has compilation errors');
  END IF;
END;
/

EXIT
