-- Tests for POLICY_RULES and V_POLICY_STATUS. Prints PASS/FAIL per check and
-- fails (exit code != 0) if any check fails. Changes nothing: ROLLBACK at end.
--
-- Run: docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 < db/tests/test_policy_rules.sql
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON
SET FEEDBACK OFF

DECLARE
  failures PLS_INTEGER := 0;
  seed_day DATE;
  anchor_5005 VARCHAR2(2);

  PROCEDURE check_eq (p_name IN VARCHAR2, p_got IN VARCHAR2, p_expected IN VARCHAR2) IS
  BEGIN
    IF p_got = p_expected OR (p_got IS NULL AND p_expected IS NULL) THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
    ELSE
      failures := failures + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || '   got=' || p_got || '   expected=' || p_expected);
    END IF;
  END check_eq;

  FUNCTION d (p_date IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_date, 'YYYY-MM-DD');
  END d;

BEGIN
  DBMS_OUTPUT.PUT_LINE('--- R6 month maths (add_periods)');
  check_eq('31 Jan + 1M = 28 Feb',                d(POLICY_RULES.add_periods(DATE '2026-01-31', 'M', 31)),    '2026-02-28');
  check_eq('31 Jan + 1M = 29 Feb (leap year)',    d(POLICY_RULES.add_periods(DATE '2028-01-31', 'M', 31)),    '2028-02-29');
  check_eq('28 Feb + 1M = 31 Mar (anchor 31)',    d(POLICY_RULES.add_periods(DATE '2026-02-28', 'M', 31)),    '2026-03-31');
  check_eq('28 Feb + 1M = 28 Mar (anchor 28)',    d(POLICY_RULES.add_periods(DATE '2026-02-28', 'M', 28)),    '2026-03-28');
  check_eq('30 Apr + 1M = 30 May (not 31)',       d(POLICY_RULES.add_periods(DATE '2026-04-30', 'M', 30)),    '2026-05-30');
  check_eq('15 Jan + 3 x 1M = 15 Apr',            d(POLICY_RULES.add_periods(DATE '2026-01-15', 'M', 15, 3)), '2026-04-15');
  check_eq('30 Nov + 1Q = 28 Feb',                d(POLICY_RULES.add_periods(DATE '2026-11-30', 'Q', 30)),    '2027-02-28');
  check_eq('31 Aug + 1H = 28 Feb',                d(POLICY_RULES.add_periods(DATE '2026-08-31', 'H', 31)),    '2027-02-28');
  check_eq('29 Feb 2028 + 1Y = 28 Feb 2029',      d(POLICY_RULES.add_periods(DATE '2028-02-29', 'Y', 29)),    '2029-02-28');
  check_eq('31 Dec + 1Y = 31 Dec',                d(POLICY_RULES.add_periods(DATE '2026-12-31', 'Y', 31)),    '2027-12-31');

  DBMS_OUTPUT.PUT_LINE('--- R2/R4 status boundaries (due 4 Oct 2026, premium 100)');
  check_eq('Q due in 31 days = PAID',             POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-09-03'), 'PAID');
  check_eq('Q due in 30 days = DUE',              POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-09-04'), 'DUE');
  check_eq('Q due today = DUE',                   POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-10-04'), 'DUE');
  check_eq('Q 1 day late = IN_GRACE',             POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-10-05'), 'IN_GRACE');
  check_eq('Q day 30 of grace = IN_GRACE',        POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-11-03'), 'IN_GRACE');
  check_eq('Q day 31 = LAPSED',                   POLICY_RULES.status(DATE '2026-10-04', 'Q', 100, DATE '2026-11-04'), 'LAPSED');
  check_eq('M day 15 of grace = IN_GRACE',        POLICY_RULES.status(DATE '2026-10-04', 'M', 100, DATE '2026-10-19'), 'IN_GRACE');
  check_eq('M day 16 = LAPSED',                   POLICY_RULES.status(DATE '2026-10-04', 'M', 100, DATE '2026-10-20'), 'LAPSED');
  check_eq('No premium = NOT_SERVICEABLE',        POLICY_RULES.status(DATE '2026-10-04', 'Q', NULL, DATE '2026-10-04'), 'NOT_SERVICEABLE');
  check_eq('No mode = NOT_SERVICEABLE',           POLICY_RULES.status(DATE '2026-10-04', NULL, 100, DATE '2026-10-04'), 'NOT_SERVICEABLE');
  check_eq('No due date = NOT_SERVICEABLE',       POLICY_RULES.status(NULL, 'Q', 100, DATE '2026-10-04'), 'NOT_SERVICEABLE');

  DBMS_OUTPUT.PUT_LINE('--- R3 today in IST');
  check_eq('today_ist = IST date (clock not frozen)',
           d(POLICY_RULES.today_ist), d(TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Kolkata' AS DATE))));
  UPDATE APP_CLOCK SET FROZEN_TODAY = DATE '2030-01-15';
  check_eq('today_ist follows frozen clock', d(POLICY_RULES.today_ist), '2030-01-15');

  -- Seed fixtures. Seed dates are "load day +/- n", and the load day depends
  -- on when the database was reset (and on UTC vs IST). Policy 5031 was
  -- loaded as due exactly on load day, so freeze the clock to that day and
  -- every fixture is checked against the day it was written for.
  SELECT NEXT_DUE_DATE INTO seed_day FROM POLICIES WHERE POLICY_ID = 5031;
  UPDATE APP_CLOCK SET FROZEN_TODAY = seed_day;
  DBMS_OUTPUT.PUT_LINE('--- Seed fixtures via V_POLICY_STATUS (clock frozen at seed load day ' || d(seed_day) || ')');

  FOR r IN (
    SELECT x.policy_id, x.expected, x.why, v.DERIVED_STATUS
    FROM (
      SELECT 5007 policy_id, 'PAID'            expected, 'Y due in 31 days'               why FROM dual UNION ALL
      SELECT 5037,           'DUE',                      'Y due in 30 days'                   FROM dual UNION ALL
      SELECT 5006,           'DUE',                      'Y due in 29 days'                   FROM dual UNION ALL
      SELECT 5031,           'DUE',                      'Q due today'                        FROM dual UNION ALL
      SELECT 5034,           'IN_GRACE',                 'Y 1 day late'                       FROM dual UNION ALL
      SELECT 5142,           'IN_GRACE',                 'H 29 days late'                     FROM dual UNION ALL
      SELECT 5001,           'IN_GRACE',                 'Q 30 days late = last grace day'    FROM dual UNION ALL
      SELECT 5066,           'IN_GRACE',                 'Q 30 days late = last grace day'    FROM dual UNION ALL
      SELECT 5002,           'LAPSED',                   'Q 31 days late'                     FROM dual UNION ALL
      SELECT 5041,           'IN_GRACE',                 'M 14 days late'                     FROM dual UNION ALL
      SELECT 5003,           'IN_GRACE',                 'M 15 days late = last grace day'    FROM dual UNION ALL
      SELECT 5004,           'LAPSED',                   'M 16 days late'                     FROM dual UNION ALL
      SELECT 5008,           'LAPSED',                   'H 800 days late'                    FROM dual UNION ALL
      SELECT 5011,           'NOT_SERVICEABLE',          'surrendered, no due date'           FROM dual UNION ALL
      SELECT 5012,           'NOT_SERVICEABLE',          'matured, no due date'               FROM dual UNION ALL
      SELECT 5013,           'NOT_SERVICEABLE',          'ACTIVE but no due date'             FROM dual UNION ALL
      SELECT 5014,           'NOT_SERVICEABLE',          'premium missing'                    FROM dual UNION ALL
      SELECT 5015,           'NOT_SERVICEABLE',          'premium 0'                          FROM dual UNION ALL
      SELECT 5016,           'NOT_SERVICEABLE',          'premium negative'                   FROM dual UNION ALL
      SELECT 5018,           'NOT_SERVICEABLE',          'SINGLE premium'                     FROM dual UNION ALL
      SELECT 5021,           'DUE',                      'customer missing, still listed'     FROM dual
    ) x
    LEFT JOIN V_POLICY_STATUS v ON v.POLICY_ID = x.policy_id
    ORDER BY x.policy_id
  ) LOOP
    check_eq(r.policy_id || ' ' || r.why, r.DERIVED_STATUS, r.expected);
  END LOOP;

  SELECT TO_CHAR(DUE_DAY_ANCHOR) INTO anchor_5005 FROM POLICIES WHERE POLICY_ID = 5005;
  check_eq('anchor of month-end policy 5005 = 31', anchor_5005, '31');

  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('--- ' || CASE WHEN failures = 0 THEN 'ALL PASSED' ELSE failures || ' FAILED' END);
  IF failures > 0 THEN
    RAISE_APPLICATION_ERROR(-20900, failures || ' test(s) failed');
  END IF;
END;
/
EXIT
