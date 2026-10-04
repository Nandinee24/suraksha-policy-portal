#!/usr/bin/env bash
# Concurrency proof for RECORD_PAYMENT: two database sessions call it for the
# same policy at the same time. Session A pays and holds its transaction open
# for a few seconds; session B starts 1 second later.
#
# Resets the database first (payments are committed here). Stop the backend.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

CONN='suraksha/suraksha@//localhost:1521/FREEPDB1'
RUN=$(date +%s)

bash reset.sh   > /dev/null
bash migrate.sh > /dev/null
echo "Database reset and migrated."

# session NAME POLICY AMOUNT KEY HOLD_SECONDS
session() {
  docker exec -i suraksha-oracle sqlplus -S -L "$CONN" <<SQL
SET SERVEROUTPUT ON FEEDBACK OFF
DECLARE
  v_id  NUMBER;
  v_due DATE;
  v_res VARCHAR2(30);
  v_seen DATE;
BEGIN
  -- What the clerk's screen shows before they press "Record".
  SELECT NEXT_DUE_DATE INTO v_seen FROM POLICIES WHERE POLICY_ID = $2;
  DBMS_OUTPUT.PUT_LINE('  $1 ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' sends key $4, sees due ' || TO_CHAR(v_seen, 'YYYY-MM-DD'));
  RECORD_PAYMENT($2, $3, '$4', 'BRANCH', v_seen, v_id, v_due, v_res);
  DBMS_OUTPUT.PUT_LINE('  $1 ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' -> ' || v_res || ', payment ' || v_id || ', next due ' || TO_CHAR(v_due, 'YYYY-MM-DD'));
  DBMS_SESSION.SLEEP($5);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  $1 ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || ' -> ' || SQLERRM);
    ROLLBACK;
END;
/
EXIT
SQL
}

echo
echo "=== 1. Double-click: same key twice on policy 5001 (expect: one RECORDED, one ALREADY_RECORDED, same payment)"
session A 5001 6000 "dbl-$RUN" 3 &
sleep 1
session B 5001 6000 "dbl-$RUN" 0
wait

echo
echo "=== 2. Two clerks: different keys on policy 5003 (expect: one RECORDED, one STALE_DUE_DATE ORA-20009)"
session A 5003 2000 "clerk1-$RUN" 3 &
sleep 1
session B 5003 2000 "clerk2-$RUN" 0
wait

echo
echo "=== 3. First transaction stuck for 8 s on policy 5004 (expect: B gives up after 5 s with POLICY_BUSY ORA-20006)"
session A 5004 1500 "slow-$RUN" 8 &
sleep 1
session B 5004 1500 "fast-$RUN" 0
wait

echo
echo "=== Result: new payments per policy (expect exactly 1 each)"
docker exec -i suraksha-oracle sqlplus -S -L "$CONN" <<SQL
SET FEEDBACK OFF
SELECT POLICY_ID, COUNT(*) AS new_payments
FROM PAYMENTS
WHERE IDEMPOTENCY_KEY LIKE '%-$RUN'
GROUP BY POLICY_ID
ORDER BY POLICY_ID;
EXIT
SQL
