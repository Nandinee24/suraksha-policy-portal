'use strict';

const express = require('express');
const { oracledb, withConnection } = require('../db');
const { AppError } = require('../errors');
const { parsePolicyId, parseListQuery, parsePayment } = require('../validate');

const router = express.Router();

// Filter shared by the page query and the count query. :status / :pattern are
// NULL when not given. POLICY_NO is stored upper case (V045); names are
// compared upper case, so the search is case-insensitive.
const LIST_FILTER = `
  WHERE (:status IS NULL OR DERIVED_STATUS = :status)
    AND (:pattern IS NULL
         OR POLICY_NO LIKE :pattern ESCAPE '\\'
         OR UPPER(CUSTOMER_NAME) LIKE :pattern ESCAPE '\\')`;

function maskPan(pan) {
  return pan ? `${pan.slice(0, 2)}******${pan.slice(-2)}` : null;
}

/**
 * GET /policies?status=&search=&page=&pageSize=
 * Filtering and paging happen in the database; the total count comes back too.
 */
router.get('/', async (req, res, next) => {
  try {
    const q = parseListQuery(req.query);
    const filterBinds = { status: q.status, pattern: q.pattern };

    const { rows, total } = await withConnection(async (conn) => {
      const page = await conn.execute(
        `SELECT POLICY_ID, POLICY_NO, CUSTOMER_NAME, PLAN_NAME, MODE_CODE, PREMIUM,
                TO_CHAR(NEXT_DUE_DATE, 'YYYY-MM-DD') AS NEXT_DUE_DATE,
                DERIVED_STATUS, AMOUNT_DUE
         FROM V_POLICY_STATUS
         ${LIST_FILTER}
         ORDER BY POLICY_ID
         OFFSET :offset ROWS FETCH NEXT :pageSize ROWS ONLY`,
        { ...filterBinds, offset: (q.page - 1) * q.pageSize, pageSize: q.pageSize },
      );
      // Separate count: COUNT(*) OVER () would give no total on a page past the end.
      const count = await conn.execute(
        `SELECT COUNT(*) AS TOTAL FROM V_POLICY_STATUS ${LIST_FILTER}`,
        filterBinds,
      );
      return { rows: page.rows, total: count.rows[0].TOTAL };
    });

    res.json({
      items: rows.map((r) => ({
        id: r.POLICY_ID,
        policyNo: r.POLICY_NO,
        customerName: r.CUSTOMER_NAME,
        planName: r.PLAN_NAME,
        mode: r.MODE_CODE,
        premium: r.PREMIUM,
        nextDueDate: r.NEXT_DUE_DATE,
        status: r.DERIVED_STATUS,
        amountDue: r.AMOUNT_DUE,
      })),
      page: q.page,
      pageSize: q.pageSize,
      total,
      totalPages: Math.ceil(total / q.pageSize),
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /policies/:id
 * Policy, customer, derived status, what to collect today, and payment
 * history newest-first (times in IST).
 */
router.get('/:id', async (req, res, next) => {
  try {
    const id = parsePolicyId(req.params.id);

    const { policy, payments } = await withConnection(async (conn) => {
      const p = await conn.execute(
        `SELECT v.POLICY_ID, v.POLICY_NO, v.PLAN_NAME, v.MODE_CODE, v.PREMIUM, v.SUM_ASSURED,
                TO_CHAR(v.COMMENCEMENT_DATE, 'YYYY-MM-DD')     AS COMMENCEMENT_DATE,
                TO_CHAR(v.NEXT_DUE_DATE, 'YYYY-MM-DD')         AS NEXT_DUE_DATE,
                TO_CHAR(v.GRACE_END_DATE, 'YYYY-MM-DD')        AS GRACE_END_DATE,
                TO_CHAR(v.FIRST_UNPAID_DUE_DATE, 'YYYY-MM-DD') AS FIRST_UNPAID_DUE_DATE,
                TO_CHAR(v.REVIVAL_DEADLINE, 'YYYY-MM-DD')      AS REVIVAL_DEADLINE,
                TO_CHAR(v.AS_OF_DATE, 'YYYY-MM-DD')            AS AS_OF_DATE,
                v.DERIVED_STATUS, v.INSTALMENTS_DUE, v.AMOUNT_DUE,
                c.CUSTOMER_ID, c.FULL_NAME, c.PAN, c.MOBILE, c.EMAIL, c.CITY
         FROM V_POLICY_STATUS v
         LEFT JOIN CUSTOMERS c ON c.CUSTOMER_ID = v.CUSTOMER_ID
         WHERE v.POLICY_ID = :id`,
        { id },
      );
      if (p.rows.length === 0) return { policy: null, payments: [] };

      // PAID_AT is stored in UTC; shown in IST. PAID_LATE: paid after the
      // grace period of the instalment it covers (judged on the IST date, R3).
      const y = await conn.execute(
        `SELECT y.PAYMENT_ID, y.AMOUNT, y.CHANNEL, y.INSTALMENTS,
                TO_CHAR(FROM_TZ(y.PAID_AT, 'UTC') AT TIME ZONE 'Asia/Kolkata',
                        'YYYY-MM-DD"T"HH24:MI:SS') || '+05:30' AS PAID_AT,
                TO_CHAR(y.COVERS_DUE_DATE, 'YYYY-MM-DD') AS COVERS_DUE_DATE,
                CASE WHEN TRUNC(CAST(FROM_TZ(y.PAID_AT, 'UTC') AT TIME ZONE 'Asia/Kolkata' AS DATE))
                          > y.COVERS_DUE_DATE + POLICY_RULES.grace_days(p.MODE_CODE)
                     THEN 1 ELSE 0 END AS PAID_LATE
         FROM PAYMENTS y
         JOIN POLICIES p ON p.POLICY_ID = y.POLICY_ID
         WHERE y.POLICY_ID = :id
         ORDER BY y.PAID_AT DESC, y.PAYMENT_ID DESC`,
        { id },
      );
      return { policy: p.rows[0], payments: y.rows };
    });

    if (!policy) throw new AppError(404, 'POLICY_NOT_FOUND', `Policy ${id} does not exist.`);

    res.json({
      policy: {
        id: policy.POLICY_ID,
        policyNo: policy.POLICY_NO,
        planName: policy.PLAN_NAME,
        mode: policy.MODE_CODE,
        premium: policy.PREMIUM,
        sumAssured: policy.SUM_ASSURED,
        commencementDate: policy.COMMENCEMENT_DATE,
        nextDueDate: policy.NEXT_DUE_DATE,
        graceEndDate: policy.GRACE_END_DATE,
        firstUnpaidDueDate: policy.FIRST_UNPAID_DUE_DATE,
        revivalDeadline: policy.REVIVAL_DEADLINE,
        status: policy.DERIVED_STATUS,
        instalmentsDue: policy.INSTALMENTS_DUE,
        amountDue: policy.AMOUNT_DUE,
        asOf: policy.AS_OF_DATE,
      },
      // Null when the policy points to a customer that does not exist (5021).
      customer: policy.CUSTOMER_ID == null ? null : {
        id: policy.CUSTOMER_ID,
        name: policy.FULL_NAME,
        pan: maskPan(policy.PAN),
        mobile: policy.MOBILE,
        email: policy.EMAIL,
        city: policy.CITY,
      },
      payments: payments.map((y) => ({
        id: y.PAYMENT_ID,
        amount: y.AMOUNT,
        paidAt: y.PAID_AT,
        coversDueDate: y.COVERS_DUE_DATE,
        channel: y.CHANNEL,
        instalments: y.INSTALMENTS,
        paidLate: y.PAID_LATE === 1,
      })),
    });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /policies/:id/payments
 * Header: Idempotency-Key
 * Body:   { "amount": 12500.00, "channel": "BRANCH", "expectedDueDate": "2026-10-04" }
 *
 * All rules (R5-R8) are enforced inside RECORD_PAYMENT. 201 for a new payment;
 * 200 + Idempotent-Replayed for a repeat of the same key, with the first result.
 */
router.post('/:id/payments', async (req, res, next) => {
  try {
    const policyId = parsePolicyId(req.params.id);
    const payment = parsePayment(req.get('Idempotency-Key'), req.body);

    const result = await withConnection((conn) => conn.execute(
      `DECLARE
         v_next_due DATE;
       BEGIN
         RECORD_PAYMENT(:policyId, :amount, :idemKey, :channel,
                        TO_DATE(:expectedDue, 'YYYY-MM-DD'),
                        :paymentId, v_next_due, :result);
         :nextDue := TO_CHAR(v_next_due, 'YYYY-MM-DD');
       END;`,
      {
        policyId,
        amount: payment.amount,
        idemKey: payment.idemKey,
        channel: payment.channel,
        expectedDue: payment.expectedDueDate,
        paymentId: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
        result: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 30 },
        nextDue: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 10 },
      },
      // One call = one transaction. If RECORD_PAYMENT raises, nothing is kept.
      { autoCommit: true },
    ));

    const { paymentId, result: outcome, nextDue } = result.outBinds;
    const replayed = outcome === 'ALREADY_RECORDED';
    if (replayed) res.set('Idempotent-Replayed', 'true');

    res.status(replayed ? 200 : 201).json({
      result: outcome,
      paymentId,
      policyId,
      amount: payment.amount,
      nextDueDate: nextDue,
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
