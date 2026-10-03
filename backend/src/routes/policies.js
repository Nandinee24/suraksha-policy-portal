'use strict';

const express = require('express');
const { withConnection } = require('../db');

const router = express.Router();

/**
 * GET /policies?status=&search=&page=&pageSize=
 *
 * TODO(candidate)
 *  - filter by derived status (PAID | DUE | IN_GRACE | LAPSED)
 *  - search by policy number OR customer name, case-insensitive
 *  - server-side pagination; return the total count too
 *  - bind variables only
 */
router.get('/', async (req, res, next) => {
  try {
    res.status(501).json({ error: 'NOT_IMPLEMENTED' });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /policies/:id
 * TODO(candidate): policy details + customer + payment history (newest first).
 */
router.get('/:id', async (req, res, next) => {
  try {
    res.status(501).json({ error: 'NOT_IMPLEMENTED' });
  } catch (err) {
    next(err);
  }
});

/**
 * POST /policies/:id/payments
 * Header: Idempotency-Key: <string>
 * Body:   { "amount": 12500.00, "channel": "BRANCH" }
 *
 * TODO(candidate)
 *  - call your RECORD_PAYMENT procedure
 *  - a repeat of the same Idempotency-Key must return the FIRST result,
 *    and must not create a second payment
 *  - map business-rule failures to sensible status codes with a machine-readable
 *    error code and a message branch staff can actually read
 */
router.post('/:id/payments', async (req, res, next) => {
  try {
    res.status(501).json({ error: 'NOT_IMPLEMENTED' });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
