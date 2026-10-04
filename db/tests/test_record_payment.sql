-- Rule tests for RECORD_PAYMENT. One session, so no concurrency here (see
-- race_test.sh). The clock is frozen to the seed load day so the seed cases
-- are exact whenever the DB was loaded. Everything is rolled back at the end.
--
-- Run: docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 < db/tests/test_record_payment.sql
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

DECLARE
  failures  PLS_INTEGER := 0;
  seed_day  DATE;
  last_id   NUMBER;
  last_due  DATE;
  first_id  NUMBER;
  due_5005  DATE;
  v_paid_at TIMESTAMP;
  v_cnt     NUMBER;

  PROCEDURE check_eq (p_name IN VARCHAR2, p_got IN VARCHAR2, p_expected IN VARCHAR2) IS
  BEGIN
    IF p_got = p_expected OR (p_got IS NULL AND p_expected IS NULL) THEN
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
    ELSE
      failures := failures + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || '   got=' || p_got || '   expected=' || p_expected);
    END IF;
  END check_eq;

  FUNCTION d (p IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p, 'YYYY-MM-DD');
  END d;

  FUNCTION due_of (p_policy IN NUMBER) RETURN DATE IS
    v DATE;
  BEGIN
    SELECT NEXT_DUE_DATE INTO v FROM POLICIES WHERE POLICY_ID = p_policy;
    RETURN v;
  END due_of;

  -- Calls RECORD_PAYMENT; "got" is the result (RECORDED / ALREADY_RECORDED)
  -- or the error code (ORA-200xx). Error messages are printed so you can
  -- read what a clerk would see.
  PROCEDURE pay (p_name     IN VARCHAR2,
                 p_policy   IN NUMBER,
                 p_amount   IN NUMBER,
                 p_key      IN VARCHAR2,
                 p_expect   IN VARCHAR2,
                 p_due      IN DATE     DEFAULT NULL,   -- NULL = the current due date
                 p_channel  IN VARCHAR2 DEFAULT 'BRANCH') IS
    v_id  NUMBER;
    v_due DATE;
    v_res VARCHAR2(30);
    v_got VARCHAR2(30);
    v_msg VARCHAR2(4000);
  BEGIN
    BEGIN
      RECORD_PAYMENT(p_policy, p_amount, p_key, p_channel,
                     CASE WHEN p_due IS NULL THEN due_of(p_policy) ELSE p_due END,
                     v_id, v_due, v_res);
      v_got    := v_res;
      last_id  := v_id;
      last_due := v_due;
    EXCEPTION
      WHEN OTHERS THEN
        v_got := 'ORA' || TO_CHAR(SQLCODE);
        v_msg := REGEXP_SUBSTR(SQLERRM, '^[^' || CHR(10) || ']*');
    END;
    check_eq(p_name, v_got, p_expect);
    IF v_msg IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('        clerk sees: ' || REGEXP_REPLACE(v_msg, '^ORA-[0-9]+: ', ''));
    END IF;
  END pay;

BEGIN
  SELECT NEXT_DUE_DATE INTO seed_day FROM POLICIES WHERE POLICY_ID = 5031;
  UPDATE APP_CLOCK SET FROZEN_TODAY = seed_day;
  DBMS_OUTPUT.PUT_LINE('Clock frozen at seed load day ' || d(seed_day));

  DBMS_OUTPUT.PUT_LINE('--- Happy path: 5001 quarterly, last day of grace (R3)');
  pay('5001 pays 6000 on last grace day', 5001, 6000, 't-5001-a', 'RECORDED', seed_day - 30);
  first_id := last_id;
  check_eq('5001 due moved one quarter (R6)', d(due_of(5001)),
           d(POLICY_RULES.add_periods(seed_day - 30, 'Q', EXTRACT(DAY FROM seed_day - 30))));
  SELECT PAID_AT INTO v_paid_at FROM PAYMENTS WHERE PAYMENT_ID = first_id;
  check_eq('PAID_AT stored in UTC (within 1 min of UTC now)',
           CASE WHEN ABS(CAST(v_paid_at AS DATE) - CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE)) < 1/1440 THEN 'Y' ELSE 'N' END, 'Y');
  SELECT COUNT(*) INTO v_cnt FROM POLICIES WHERE POLICY_ID = 5001 AND FIRST_UNPAID_DUE_DATE IS NULL;
  check_eq('5001 first unpaid date cleared', TO_CHAR(v_cnt), '1');

  DBMS_OUTPUT.PUT_LINE('--- R8 idempotency');
  pay('same key again = first result',             5001, 6000, 't-5001-a', 'ALREADY_RECORDED', seed_day - 30);
  check_eq('replay returns the same payment id', TO_CHAR(last_id), TO_CHAR(first_id));
  SELECT COUNT(*) INTO v_cnt FROM PAYMENTS WHERE IDEMPOTENCY_KEY = 't-5001-a';
  check_eq('still only one payment for that key', TO_CHAR(v_cnt), '1');
  pay('same key, different amount',                5001, 6001, 't-5001-a', 'ORA-20005');
  pay('same key, different policy',                5003, 6000, 't-5001-a', 'ORA-20005');
  pay('legacy key on its own payment = replay',    5001, 6000, 'legacy-00000001-4376', 'ALREADY_RECORDED');
  pay('stale due date (clerk saw the old one)',    5001, 6000, 't-5001-b', 'ORA-20009', seed_day - 30);

  DBMS_OUTPUT.PUT_LINE('--- R5 exact amount');
  pay('5003 underpaid by 1 rupee',                 5003, 1999,    't-5003-a', 'ORA-20003');
  pay('5003 overpaid',                             5003, 2000.01, 't-5003-b', 'ORA-20003');
  pay('5003 monthly, last day of grace (15)',      5003, 2000,    't-5003-c', 'RECORDED');

  DBMS_OUTPUT.PUT_LINE('--- Not payable');
  pay('5007 due in 31 days = nothing due',         5007, 36000, 't-5007-a', 'ORA-20008');
  pay('5018 SINGLE premium',                       5018, 60000, 't-5018-a', 'ORA-20002', seed_day + 20);
  pay('5014 no premium',                           5014, 1,     't-5014-a', 'ORA-20002', seed_day + 10);
  pay('policy that does not exist',                999999, 100, 't-none-a', 'ORA-20001', seed_day);
  pay('missing key',                               5006, 24000, NULL,       'ORA-20007');
  pay('unknown channel',                           5006, 24000, 't-5006-a', 'ORA-20007', NULL, 'CASH');
  pay('amount with 3 decimals',                    5006, 24000.001, 't-5006-b', 'ORA-20007');

  DBMS_OUTPUT.PUT_LINE('--- R7 revival window (first unpaid 729 / 730 / 731 days ago)');
  pay('5009 731 days: window closed',              5009, 9000,  't-5009-a', 'ORA-20004');
  pay('5008 730 days: single premium is not enough', 5008, 12000, 't-5008-a', 'ORA-20003');
  pay('5008 730 days: all 5 pending premiums',     5008, 60000, 't-5008-b', 'RECORDED');
  check_eq('5008 status after revival', POLICY_RULES.status(due_of(5008), 'H', 12000, seed_day), 'PAID');
  pay('5010 729 days: all 5 pending premiums',     5010, 37500, 't-5010-a', 'RECORDED');
  pay('5002 lapsed 1 day ago: revive with 1 premium', 5002, 4200, 't-5002-a', 'RECORDED');

  DBMS_OUTPUT.PUT_LINE('--- Legacy data');
  pay('5023: legacy already paid this instalment', 5023, 4200,  't-5023-a', 'ORA-20010');
  pay('5019: duplicate policy no (NOVALIDATE) is still payable', 5019, 6000, 't-5019-a', 'RECORDED');

  DBMS_OUTPUT.PUT_LINE('--- R6 month-end chain on 5005 (monthly, due on the last day)');
  due_5005 := due_of(5005);
  FOR k IN 1 .. 5 LOOP
    last_due := due_of(5005);                                -- local function: not allowed inside SQL (PLS-00231)
    UPDATE APP_CLOCK SET FROZEN_TODAY = last_due;            -- pay on the due date
    pay('5005 payment ' || k, 5005, 2500, 't-5005-' || k, 'RECORDED');
    check_eq('5005 next due is last day of month +' || k,
             d(due_of(5005)), d(LAST_DAY(ADD_MONTHS(due_5005, k))));
  END LOOP;

  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('--- ' || CASE WHEN failures = 0 THEN 'ALL PASSED' ELSE failures || ' FAILED' END);
  IF failures > 0 THEN
    RAISE_APPLICATION_ERROR(-20900, failures || ' test(s) failed');
  END IF;
END;
/
EXIT
