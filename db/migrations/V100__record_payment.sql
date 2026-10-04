WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET FEEDBACK ON
PROMPT V100: RECORD_PAYMENT (R5-R8, atomic, safe under concurrency)

-- Error codes (the backend maps these to HTTP status + machine-readable code):
--   -20001 POLICY_NOT_FOUND         -20006 POLICY_BUSY (lock wait timed out)
--   -20002 POLICY_NOT_SERVICEABLE   -20007 INVALID_INPUT
--   -20003 AMOUNT_MISMATCH          -20008 NOT_YET_DUE
--   -20004 REVIVAL_WINDOW_EXPIRED   -20009 STALE_DUE_DATE
--   -20005 IDEMPOTENCY_KEY_REUSED   -20010 INSTALMENT_ALREADY_PAID
--
-- Signature change from the stub: P_EXPECTED_DUE added and required. It is the
-- due date the clerk saw. Without it, two clerks paying the same policy at the
-- same moment would both succeed: the second waits for the lock, then pays the
-- NEXT instalment. R8 says they must not both succeed.
--
-- No COMMIT here: the caller commits. If anything fails, the whole call is
-- rolled back, so the payment insert and the policy update are atomic.
CREATE OR REPLACE PROCEDURE RECORD_PAYMENT (
  P_POLICY_ID     IN  NUMBER,
  P_AMOUNT        IN  NUMBER,
  P_IDEM_KEY      IN  VARCHAR2,
  P_CHANNEL       IN  VARCHAR2,
  P_EXPECTED_DUE  IN  DATE,
  O_PAYMENT_ID    OUT NUMBER,
  O_NEXT_DUE      OUT DATE,
  O_RESULT        OUT VARCHAR2      -- RECORDED / ALREADY_RECORDED
) AS
  v_pol       POLICIES%ROWTYPE;
  v_prev      PAYMENTS%ROWTYPE;
  v_today     DATE;
  v_status    VARCHAR2(20);
  v_n         PLS_INTEGER;
  v_expected  NUMBER;
  v_new_due   DATE;

  -- Lock wait timed out. Oracle 23 reports FOR UPDATE WAIT timeouts as
  -- ORA-00054 (found by db/tests/race_test.sh); older versions use ORA-30006.
  e_lock_timeout EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_lock_timeout, -30006);
  e_lock_busy EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_lock_busy, -54);

  FUNCTION money (p IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'Rs. ' || TO_CHAR(p, 'FM99,99,99,990.00');
  END money;

  FUNCTION nice (p IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p, 'DD Mon YYYY');
  END nice;

  -- Has this key been used already? Loads the earlier payment into v_prev.
  FUNCTION key_used RETURN BOOLEAN IS
  BEGIN
    SELECT * INTO v_prev FROM PAYMENTS WHERE IDEMPOTENCY_KEY = P_IDEM_KEY;
    RETURN TRUE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN FALSE;
  END key_used;

  -- Same key again: return the first result, never a second payment.
  -- Same key with a different policy or amount is a client bug: refuse it.
  PROCEDURE replay IS
  BEGIN
    IF v_prev.POLICY_ID <> P_POLICY_ID OR v_prev.AMOUNT <> P_AMOUNT THEN
      RAISE_APPLICATION_ERROR(-20005,
        'This request ID was already used for a different payment. Start a new payment.');
    END IF;
    O_PAYMENT_ID := v_prev.PAYMENT_ID;
    O_NEXT_DUE   := v_prev.NEXT_DUE_AFTER;
    O_RESULT     := 'ALREADY_RECORDED';
  END replay;

BEGIN
  -- 1. Input
  IF P_IDEM_KEY IS NULL OR LENGTH(P_IDEM_KEY) > 64 THEN
    RAISE_APPLICATION_ERROR(-20007, 'A request ID (Idempotency-Key, max 64 characters) is required.');
  ELSIF P_AMOUNT IS NULL OR P_AMOUNT <= 0 OR P_AMOUNT <> ROUND(P_AMOUNT, 2) THEN
    RAISE_APPLICATION_ERROR(-20007, 'Amount must be a positive value in rupees and paise.');
  ELSIF P_CHANNEL IS NULL OR P_CHANNEL NOT IN ('BRANCH', 'ONLINE', 'AGENT', 'AUTO-DEBIT') THEN
    RAISE_APPLICATION_ERROR(-20007, 'Channel must be BRANCH, ONLINE, AGENT or AUTO-DEBIT.');
  ELSIF P_EXPECTED_DUE IS NULL THEN
    RAISE_APPLICATION_ERROR(-20007, 'The due date shown to the clerk is required.');
  END IF;

  -- 2. Lock the policy row. A second call for the same policy waits here
  --    until the first one commits or rolls back (max 5 seconds).
  BEGIN
    SELECT * INTO v_pol FROM POLICIES WHERE POLICY_ID = P_POLICY_ID FOR UPDATE WAIT 5;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'Policy ' || P_POLICY_ID || ' does not exist.');
    WHEN e_lock_timeout OR e_lock_busy THEN
      RAISE_APPLICATION_ERROR(-20006,
        'Another payment for this policy is being processed. Please try again in a moment.');
  END;

  -- 3. Same key seen before? Checked AFTER the lock: a duplicate request that
  --    was waiting now sees the first request's committed payment.
  IF key_used THEN
    replay;
    RETURN;
  END IF;

  v_today  := POLICY_RULES.today_ist;
  v_status := POLICY_RULES.status(v_pol.NEXT_DUE_DATE, v_pol.MODE_CODE, v_pol.PREMIUM, v_today);

  -- 4. Policy must be serviceable.
  IF v_status = 'NOT_SERVICEABLE' THEN
    RAISE_APPLICATION_ERROR(-20002,
      'Policy ' || v_pol.POLICY_NO || ' cannot take payments: its premium, mode or due date is missing. Refer to the servicing team.');
  END IF;

  -- 5. The clerk must be looking at the current due date (R8: two different
  --    requests for the same policy must not both succeed).
  IF P_EXPECTED_DUE <> v_pol.NEXT_DUE_DATE THEN
    RAISE_APPLICATION_ERROR(-20009,
      'This policy was just updated (next due date is now ' || nice(v_pol.NEXT_DUE_DATE) ||
      '). Refresh the page and check before collecting.');
  END IF;

  -- 6. Nothing to collect yet (decision: no advance payments).
  IF v_status = 'PAID' THEN
    RAISE_APPLICATION_ERROR(-20008,
      'Nothing is due yet. The next premium is due on ' || nice(v_pol.NEXT_DUE_DATE) || '.');
  END IF;

  -- 7. R7: a lapsed policy can only be revived inside the 2-year window.
  IF v_status = 'LAPSED'
     AND v_today > PAYMENT_RULES.revival_deadline(v_pol.FIRST_UNPAID_DUE_DATE, v_pol.NEXT_DUE_DATE) THEN
    RAISE_APPLICATION_ERROR(-20004,
      'This policy lapsed and could only be revived until ' ||
      nice(PAYMENT_RULES.revival_deadline(v_pol.FIRST_UNPAID_DUE_DATE, v_pol.NEXT_DUE_DATE)) ||
      '. The payment cannot be accepted. Refer the customer to the servicing team.');
  END IF;

  -- 8. R5: exact amount. Revival = all pending instalments in one payment.
  v_n        := PAYMENT_RULES.instalments_due(v_pol.NEXT_DUE_DATE, v_pol.MODE_CODE, v_pol.DUE_DAY_ANCHOR, v_today);
  v_expected := v_n * v_pol.PREMIUM;
  IF P_AMOUNT <> v_expected THEN
    RAISE_APPLICATION_ERROR(-20003,
      'Please collect exactly ' || money(v_expected) ||
      CASE WHEN v_n > 1 THEN ' (' || v_n || ' pending premiums of ' || money(v_pol.PREMIUM) || ' to revive the policy)' END ||
      '. Received ' || money(P_AMOUNT) || '. Part payments and extra amounts cannot be accepted.');
  END IF;

  -- 9. R6: move the due date forward by exactly N mode periods.
  v_new_due := POLICY_RULES.add_periods(v_pol.NEXT_DUE_DATE, v_pol.MODE_CODE, v_pol.DUE_DAY_ANCHOR, v_n);

  INSERT INTO PAYMENTS (PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY,
                        COVERS_DUE_DATE, CHANNEL, NEXT_DUE_AFTER, INSTALMENTS)
  VALUES (SEQ_PAYMENT_ID.NEXTVAL, P_POLICY_ID, P_AMOUNT,
          SYS_EXTRACT_UTC(SYSTIMESTAMP),          -- PAID_AT is stored in UTC
          P_IDEM_KEY, v_pol.NEXT_DUE_DATE, P_CHANNEL, v_new_due, v_n)
  RETURNING PAYMENT_ID INTO O_PAYMENT_ID;

  UPDATE POLICIES
  SET NEXT_DUE_DATE         = v_new_due,
      -- Nothing is overdue after paying every pending instalment.
      FIRST_UNPAID_DUE_DATE = CASE WHEN v_new_due < v_today THEN v_new_due END
  WHERE POLICY_ID = P_POLICY_ID;

  O_NEXT_DUE := v_new_due;
  O_RESULT   := 'RECORDED';

EXCEPTION
  -- Backstop for the unique constraints.
  WHEN DUP_VAL_ON_INDEX THEN
    IF key_used THEN
      replay;     -- same key raced in from a request for another policy
    ELSE
      -- UQ_PAY_POLICY_DUE: legacy data already holds a payment for this
      -- instalment even though the policy was never moved forward.
      RAISE_APPLICATION_ERROR(-20010,
        'A payment for the premium due on ' || nice(v_pol.NEXT_DUE_DATE) ||
        ' is already on record, but the policy was not updated. Refer to the servicing team.');
    END IF;
END RECORD_PAYMENT;
/

SHOW ERRORS PROCEDURE RECORD_PAYMENT
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM USER_ERRORS WHERE NAME = 'RECORD_PAYMENT';
  IF n > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, 'RECORD_PAYMENT has compilation errors');
  END IF;
END;
/

EXIT
