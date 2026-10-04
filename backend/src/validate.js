'use strict';

const { AppError } = require('./errors');

const STATUSES = ['PAID', 'DUE', 'IN_GRACE', 'LAPSED', 'NOT_SERVICEABLE'];
const CHANNELS = ['BRANCH', 'ONLINE', 'AGENT', 'AUTO-DEBIT'];
const MAX_PAGE_SIZE = 100;

function invalid(message, field) {
  return new AppError(400, 'VALIDATION_ERROR', message, field ? { field } : undefined);
}

function parsePolicyId(raw) {
  if (!/^\d{1,10}$/.test(String(raw))) throw invalid('Policy id must be a number.', 'id');
  return Number(raw);
}

function parsePositiveInt(raw, fallback, field, max) {
  if (raw === undefined || raw === '') return fallback;
  if (typeof raw !== 'string' || !/^\d{1,6}$/.test(raw) || Number(raw) < 1) {
    throw invalid(`${field} must be a whole number of 1 or more.`, field);
  }
  return max ? Math.min(Number(raw), max) : Number(raw);
}

// Turns the search box text into a LIKE pattern. Upper-cased (names are
// compared with UPPER), spaces collapsed, and % _ \ escaped so typing "50%"
// searches for "50%" instead of matching everything.
function toLikePattern(raw) {
  if (raw === undefined) return null;
  if (typeof raw !== 'string') throw invalid('search must be text.', 'search');
  const text = raw.trim().replace(/\s+/g, ' ');
  if (text === '') return null;
  if (text.length > 60) throw invalid('search can be at most 60 characters.', 'search');
  return `%${text.toUpperCase().replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

function parseListQuery(query) {
  const status = query.status === undefined || query.status === '' ? null : query.status;
  if (status !== null && !STATUSES.includes(status)) {
    throw invalid(`status must be one of ${STATUSES.join(', ')}.`, 'status');
  }
  return {
    status,
    pattern: toLikePattern(query.search),
    page: parsePositiveInt(query.page, 1, 'page'),
    pageSize: parsePositiveInt(query.pageSize, 20, 'pageSize', MAX_PAGE_SIZE),
  };
}

function isRealDate(text) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return false;
  const [y, m, d] = text.split('-').map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
}

function parsePayment(idemKeyHeader, body) {
  const idemKey = (idemKeyHeader || '').trim();
  if (!idemKey) {
    throw new AppError(400, 'IDEMPOTENCY_KEY_REQUIRED', 'The Idempotency-Key header is required.');
  }
  if (idemKey.length > 64 || !/^[A-Za-z0-9._:-]+$/.test(idemKey)) {
    throw invalid('Idempotency-Key must be 1-64 letters, digits or . _ : -', 'Idempotency-Key');
  }

  const data = body && typeof body === 'object' ? body : {};

  // Amount as rupees with at most 2 decimals. Checked as text so 2000.001 is
  // rejected instead of silently rounded. The exact-premium rule (R5) is
  // enforced in the database, not here.
  const amountText = typeof data.amount === 'number' || typeof data.amount === 'string'
    ? String(data.amount).trim() : '';
  if (!/^\d{1,10}(\.\d{1,2})?$/.test(amountText) || Number(amountText) <= 0) {
    throw invalid('Amount must be a positive number in rupees with at most 2 decimals.', 'amount');
  }

  const channel = data.channel === undefined ? 'BRANCH' : data.channel;
  if (!CHANNELS.includes(channel)) {
    throw invalid(`channel must be one of ${CHANNELS.join(', ')}.`, 'channel');
  }

  // The due date the clerk saw. Required: it is what stops two clerks paying
  // the same policy at the same moment from both succeeding (R8).
  if (typeof data.expectedDueDate !== 'string' || !isRealDate(data.expectedDueDate)) {
    throw invalid('expectedDueDate (YYYY-MM-DD, the due date shown on screen) is required.', 'expectedDueDate');
  }

  return { idemKey, amount: Number(amountText), channel, expectedDueDate: data.expectedDueDate };
}

module.exports = { parsePolicyId, parseListQuery, parsePayment, STATUSES, CHANNELS };
