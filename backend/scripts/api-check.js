'use strict';

/**
 * End-to-end checks against the running API (npm run dev). Prints PASS/FAIL,
 * exits 1 on any failure. Records real payments: reset the database after
 * (bash db/reset.sh && bash db/migrate.sh). Expects a freshly loaded seed.
 *
 * Run: npm run api-check
 */

const BASE = process.env.API_URL || 'http://localhost:3001';
let failures = 0;

function check(name, ok, detail) {
  if (ok) {
    console.log(`PASS  ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL  ${name}${detail ? `   ${detail}` : ''}`);
  }
}

async function call(method, path, { body, key, rawBody } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (key) headers['Idempotency-Key'] = key;
  const res = await fetch(BASE + path, {
    method,
    headers,
    body: rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, headers: res.headers, body: text ? JSON.parse(text) : null };
}

function expectError(name, r, status, code) {
  check(`${name} -> ${status} ${code}`, r.status === status && r.body && r.body.error === code,
    `got ${r.status} ${JSON.stringify(r.body)}`);
  if (r.body && r.body.message) console.log(`        message: ${r.body.message}`);
}

async function dueOf(id) {
  return (await call('GET', `/policies/${id}`)).body.policy;
}

async function main() {
  const run = Date.now();

  console.log('--- Health and routing');
  check('GET /health is 200', (await call('GET', '/health')).status === 200);
  expectError('unknown route', await call('GET', '/nope'), 404, 'NOT_FOUND');

  console.log('--- GET /policies (list)');
  let r = await call('GET', '/policies');
  check('first page: 20 items, total 194, 10 pages',
    r.status === 200 && r.body.items.length === 20 && r.body.total === 194 && r.body.totalPages === 10,
    JSON.stringify({ status: r.status, n: r.body.items && r.body.items.length, total: r.body.total }));

  r = await call('GET', '/policies?status=LAPSED&pageSize=100');
  check('status=LAPSED returns only LAPSED', r.status === 200 && r.body.total > 0
    && r.body.items.every((p) => p.status === 'LAPSED'), `total=${r.body.total}`);

  expectError('status=BAD', await call('GET', '/policies?status=BAD'), 400, 'VALIDATION_ERROR');
  expectError('page=0', await call('GET', '/policies?page=0'), 400, 'VALIDATION_ERROR');

  r = await call('GET', '/policies?search=rajesh');
  check('search "rajesh" is case-insensitive on name', r.status === 200 && r.body.total >= 3
    && r.body.items.every((p) => /rajesh/i.test(p.customerName)), `total=${r.body.total}`);

  r = await call('GET', '/policies?search=sl-2024-000120');
  check('search by policy no, lower case, finds the duplicate pair', r.body.total === 2);

  r = await call('GET', '/policies?search=50%25');
  check('search "50%" is literal, not a wildcard', r.status === 200 && r.body.total === 0, `total=${r.body.total}`);

  r = await call('GET', '/policies?page=999');
  check('page past the end: no items, total still 194', r.body.items.length === 0 && r.body.total === 194);

  r = await call('GET', '/policies?pageSize=1000');
  check('pageSize capped at 100', r.body.pageSize === 100 && r.body.items.length === 100);

  console.log('--- GET /policies/:id (detail)');
  expectError('id not a number', await call('GET', '/policies/abc'), 400, 'VALIDATION_ERROR');
  expectError('unknown policy', await call('GET', '/policies/123456'), 404, 'POLICY_NOT_FOUND');

  r = await call('GET', '/policies/5021');
  check('5021: missing customer -> customer null, still served', r.status === 200 && r.body.customer === null);

  r = await call('GET', '/policies/5001');
  check('5001: masked PAN, IST payment times, newest first',
    /^\w{2}\*{6}\w{2}$/.test(r.body.customer.pan)
    && r.body.payments.every((y) => y.paidAt.endsWith('+05:30'))
    && r.body.payments.every((y, i, a) => i === 0 || a[i - 1].paidAt >= y.paidAt));

  const late = (await call('GET', '/policies/5023')).body.payments.find((y) => y.id === 700465);
  const onTime = (await call('GET', '/policies/5024')).body.payments.find((y) => y.id === 700466);
  check('R3: 00:30 IST on day after grace = late; 23:30 IST on last day = on time',
    late && late.paidLate === true && onTime && onTime.paidLate === false);

  console.log('--- POST /policies/:id/payments');
  const p5003 = await dueOf(5003);
  const body5003 = (amount) => ({ amount, channel: 'BRANCH', expectedDueDate: p5003.nextDueDate });

  expectError('no Idempotency-Key', await call('POST', '/policies/5003/payments', { body: body5003(2000) }),
    400, 'IDEMPOTENCY_KEY_REQUIRED');
  expectError('amount "abc"', await call('POST', '/policies/5003/payments', { body: body5003('abc'), key: `k1-${run}` }),
    400, 'VALIDATION_ERROR');
  expectError('3 decimals', await call('POST', '/policies/5003/payments', { body: body5003(2000.001), key: `k2-${run}` }),
    400, 'VALIDATION_ERROR');
  expectError('no expectedDueDate', await call('POST', '/policies/5003/payments', { body: { amount: 2000 }, key: `k3-${run}` }),
    400, 'VALIDATION_ERROR');
  expectError('broken JSON', await call('POST', '/policies/5003/payments', { rawBody: '{"amount":', key: `k4-${run}` }),
    400, 'VALIDATION_ERROR');
  expectError('R5 underpaid', await call('POST', '/policies/5003/payments', { body: body5003(1999), key: `k5-${run}` }),
    422, 'AMOUNT_MISMATCH');

  const p5009 = await dueOf(5009);
  expectError('R7 revival window closed', await call('POST', '/policies/5009/payments',
    { body: { amount: 9000, expectedDueDate: p5009.nextDueDate }, key: `k6-${run}` }), 422, 'REVIVAL_WINDOW_EXPIRED');

  const p5007 = await dueOf(5007);
  expectError('nothing due yet', await call('POST', '/policies/5007/payments',
    { body: { amount: 36000, expectedDueDate: p5007.nextDueDate }, key: `k7-${run}` }), 422, 'NOT_YET_DUE');

  const p5018 = await dueOf(5018);
  expectError('SINGLE premium policy', await call('POST', '/policies/5018/payments',
    { body: { amount: 60000, expectedDueDate: p5018.nextDueDate }, key: `k8-${run}` }), 422, 'POLICY_NOT_SERVICEABLE');

  expectError('unknown policy', await call('POST', '/policies/123456/payments',
    { body: { amount: 100, expectedDueDate: '2026-01-01' }, key: `k9-${run}` }), 404, 'POLICY_NOT_FOUND');

  const p5023 = await dueOf(5023);
  expectError('legacy already paid this instalment', await call('POST', '/policies/5023/payments',
    { body: { amount: 4200, expectedDueDate: p5023.nextDueDate }, key: `k10-${run}` }), 409, 'INSTALMENT_ALREADY_PAID');

  const p5001 = await dueOf(5001);
  expectError('stale due date', await call('POST', '/policies/5001/payments',
    { body: { amount: 6000, expectedDueDate: '2020-01-01' }, key: `k11-${run}` }), 409, 'STALE_DUE_DATE');

  const payKey = `pay-${run}`;
  const payBody = { amount: p5001.amountDue, channel: 'BRANCH', expectedDueDate: p5001.nextDueDate };
  const first = await call('POST', '/policies/5001/payments', { body: payBody, key: payKey });
  check('5001 pays amountDue -> 201 RECORDED', first.status === 201 && first.body.result === 'RECORDED',
    JSON.stringify(first.body));

  const again = await call('POST', '/policies/5001/payments', { body: payBody, key: payKey });
  check('same request again -> 200, same payment, Idempotent-Replayed header',
    again.status === 200 && again.body.result === 'ALREADY_RECORDED'
    && again.body.paymentId === first.body.paymentId && again.headers.get('idempotent-replayed') === 'true',
    JSON.stringify(again.body));

  expectError('same key, different amount', await call('POST', '/policies/5001/payments',
    { body: { ...payBody, amount: 6001 }, key: payKey }), 409, 'IDEMPOTENCY_KEY_REUSED');

  const after = await dueOf(5001);
  check('5001 next due moved and status no longer IN_GRACE',
    after.nextDueDate === first.body.nextDueDate && after.status !== 'IN_GRACE', JSON.stringify(after));

  console.log(`--- ${failures === 0 ? 'ALL PASSED' : `${failures} FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('api-check could not run:', err.message);
  process.exit(1);
});
