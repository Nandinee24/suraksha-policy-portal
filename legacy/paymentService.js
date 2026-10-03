/**
 * legacy/paymentService.js
 *
 * Written in 2023 by a developer who has since left. It is still running in
 * the branch tool today. We are rewriting it, but before we do we want a
 * second pair of eyes on it.
 *
 * DO NOT FIX THIS FILE. Review it. Write what you find in REVIEW.md:
 * what is wrong, why it matters in production, and how you would fix it.
 *
 * Ordered roughly worst-first is helpful but not required.
 */

const oracledb = require('oracledb');

let pool;

async function init() {
  pool = await oracledb.createPool({
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    connectString: process.env.DB_CONNECT_STRING,
    poolMin: 1,
    poolMax: 4,
  });
}

/**
 * Branch staff hit this when they record a premium payment at the counter.
 */
async function recordPayment(policyId, amount, idemKey, channel) {
  const conn = await pool.getConnection();

  console.log('[recordPayment] incoming', { policyId, amount, idemKey });

  // Has this key already been used?
  const dupe = await conn.execute(
    "SELECT PAYMENT_ID FROM PAYMENTS WHERE IDEMPOTENCY_KEY = '" + idemKey + "'"
  );
  if (dupe.rows.length > 0) {
    await conn.close();
    return { ok: true, duplicate: true, paymentId: dupe.rows[0][0] };
  }

  const pol = await conn.execute(
    "SELECT POLICY_ID, POLICY_NO, CUSTOMER_ID, PREMIUM_MODE, PREMIUM_AMOUNT, NEXT_DUE_DATE, " +
    "FIRST_UNPAID_DUE_DATE FROM POLICIES WHERE POLICY_ID = " + policyId
  );

  const row = pol.rows[0];
  console.log('[recordPayment] policy row =', JSON.stringify(row));

  const premium = parseFloat(row[4]);
  const mode = row[3];
  const nextDue = row[5];

  // The amount has to match the premium for this mode.
  if (amount != premium) {
    await conn.close();
    return { ok: false, error: 'Amount does not match premium' };
  }

  // Is the policy still inside its grace period?
  const today = new Date();
  const graceEnd = new Date(nextDue);
  graceEnd.setDate(graceEnd.getDate() + 30);
  if (today > graceEnd) {
    await conn.close();
    return { ok: false, error: 'Policy has lapsed' };
  }

  // Work out the new due date.
  let days = 365;
  if (mode == 'M') days = 30;
  else if (mode == 'Q') days = 90;
  else if (mode == 'H') days = 180;

  const newDue = new Date(nextDue);
  newDue.setDate(newDue.getDate() + days);

  const paymentId = Math.floor(Math.random() * 100000000);

  await conn.execute(
    "INSERT INTO PAYMENTS (PAYMENT_ID, POLICY_ID, AMOUNT, PAID_AT, IDEMPOTENCY_KEY, COVERS_DUE_DATE, CHANNEL) " +
    "VALUES (:id, :pid, :amt, SYSTIMESTAMP, :key, :covers, :ch)",
    { id: paymentId, pid: policyId, amt: amount, key: idemKey, covers: nextDue, ch: channel },
    { autoCommit: true }
  );

  await conn.execute(
    "UPDATE POLICIES SET NEXT_DUE_DATE = :nd WHERE POLICY_ID = :pid",
    { nd: newDue, pid: policyId },
    { autoCommit: true }
  );

  await conn.close();

  return { ok: true, paymentId: paymentId, nextDue: newDue };
}

/**
 * Powers the branch dashboard list.
 */
async function listPoliciesWithTotals(search) {
  const conn = await pool.getConnection();

  let sql = "SELECT POLICY_ID, POLICY_NO, CUSTOMER_ID, PREMIUM_AMOUNT FROM POLICIES";
  if (search) {
    sql += " WHERE POLICY_NO LIKE '%" + search + "%' OR CUSTOMER_ID IN " +
           "(SELECT CUSTOMER_ID FROM CUSTOMERS WHERE FULL_NAME LIKE '%" + search + "%')";
  }

  const result = await conn.execute(sql);

  const out = [];
  for (const r of result.rows) {
    const pays = await conn.execute(
      "SELECT AMOUNT FROM PAYMENTS WHERE POLICY_ID = " + r[0]
    );
    let total = 0;
    for (const p of pays.rows) {
      total = total + p[0];
    }
    out.push({ policyId: r[0], policyNo: r[1], totalPaid: total });
  }

  await conn.close();
  return out;
}

module.exports = { init, recordPayment, listPoliciesWithTotals };
