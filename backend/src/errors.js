'use strict';

/**
 * An error the API returns on purpose: HTTP status + machine-readable code +
 * a message a branch clerk can read.
 */
class AppError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

// RAISE_APPLICATION_ERROR codes from RECORD_PAYMENT (db/migrations/V100).
// 400 = fix the request, 404 = no such policy, 409 = conflict with another
// request or with existing data (refresh / retry), 422 = valid request that a
// business rule refuses.
const BUSINESS_ERRORS = {
  20001: [404, 'POLICY_NOT_FOUND'],
  20002: [422, 'POLICY_NOT_SERVICEABLE'],
  20003: [422, 'AMOUNT_MISMATCH'],
  20004: [422, 'REVIVAL_WINDOW_EXPIRED'],
  20005: [409, 'IDEMPOTENCY_KEY_REUSED'],
  20006: [409, 'POLICY_BUSY'],
  20007: [400, 'VALIDATION_ERROR'],
  20008: [422, 'NOT_YET_DUE'],
  20009: [409, 'STALE_DUE_DATE'],
  20010: [409, 'INSTALMENT_ALREADY_PAID'],
};

// Database unreachable or pool exhausted: the client should try again later.
// NJS-040 = waited too long for a pool connection; NJS-5xx = network errors
// (Thin mode); ORA-125xx/031xx = listener down or connection lost.
function isDbUnavailable(err) {
  const code = (err && err.code) || '';
  return code === 'NJS-040' || /^NJS-5\d\d$/.test(code)
    || [12514, 12541, 12170, 3113, 3114, 3135].includes(err && err.errorNum);
}

// "ORA-20003: Please collect ...\nORA-06512: at ..." -> "Please collect ..."
function cleanOracleMessage(message) {
  return String(message).split('\n')[0].replace(/^ORA-\d+:\s*/, '').trim();
}

function toAppError(err) {
  if (err instanceof AppError) return err;

  if (err && err.type === 'entity.parse.failed') {
    return new AppError(400, 'VALIDATION_ERROR', 'The request body is not valid JSON.');
  }

  const business = err && BUSINESS_ERRORS[err.errorNum];
  if (business) {
    return new AppError(business[0], business[1], cleanOracleMessage(err.message));
  }

  if (err && (err.errorNum === 54 || err.errorNum === 30006)) {
    return new AppError(409, 'POLICY_BUSY',
      'Another payment for this policy is being processed. Please try again in a moment.');
  }

  if (err && err.errorNum === 1) {
    return new AppError(409, 'CONFLICT', 'This change conflicts with data that already exists.');
  }

  if (isDbUnavailable(err)) {
    return new AppError(503, 'DB_UNAVAILABLE', 'The database is not reachable. Please try again shortly.');
  }

  return new AppError(500, 'INTERNAL', 'Something went wrong. Please try again.');
}

module.exports = { AppError, toAppError };
