'use strict';

/**
 * R8 through the whole stack: fires parallel POSTs at the running API.
 *  1. 10 identical requests (double-click / network retries, same key)
 *     -> exactly one 201, the rest 200 with the SAME payment id.
 *  2. 10 requests with different keys (10 clerks at once) on another policy
 *     -> exactly one 201, the rest refused (409).
 * Records real payments: reset the database afterwards.
 *
 * Run: npm run race-test
 */

const BASE = process.env.API_URL || 'http://localhost:3001';
const PARALLEL = 10;

async function post(policyId, body, key) {
  const res = await fetch(`${BASE}/policies/${policyId}/payments`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

async function policy(id) {
  const res = await fetch(`${BASE}/policies/${id}`);
  return (await res.json()).policy;
}

function tally(results) {
  const counts = {};
  for (const r of results) {
    const label = `${r.status} ${r.body.result || r.body.error}`;
    counts[label] = (counts[label] || 0) + 1;
  }
  return counts;
}

async function main() {
  const run = Date.now();
  let ok = true;

  // 1. Same key, 10 times at once.
  const p1 = await policy(5001);
  const body1 = { amount: p1.amountDue, channel: 'BRANCH', expectedDueDate: p1.nextDueDate };
  const same = await Promise.all(
    Array.from({ length: PARALLEL }, () => post(5001, body1, `race-same-${run}`)),
  );
  const created1 = same.filter((r) => r.status === 201);
  const ids = new Set(same.map((r) => r.body.paymentId));
  console.log(`1. ${PARALLEL} x same key on 5001:`, tally(same));
  const pass1 = created1.length === 1 && ids.size === 1
    && same.every((r) => r.status === 201 || r.status === 200);
  console.log(`   ${pass1 ? 'PASS' : 'FAIL'}  one payment created, every response has payment ${[...ids].join(', ')}`);
  ok = ok && pass1;

  // 2. Different keys, 10 at once, all looking at the same due date.
  const p2 = await policy(5003);
  const body2 = { amount: p2.amountDue, channel: 'BRANCH', expectedDueDate: p2.nextDueDate };
  const diff = await Promise.all(
    Array.from({ length: PARALLEL }, (_, i) => post(5003, body2, `race-clerk${i}-${run}`)),
  );
  const created2 = diff.filter((r) => r.status === 201);
  console.log(`2. ${PARALLEL} x different keys on 5003:`, tally(diff));
  const pass2 = created2.length === 1 && diff.every((r) => r.status === 201 || r.status === 409);
  console.log(`   ${pass2 ? 'PASS' : 'FAIL'}  exactly one payment, all others refused with 409`);
  ok = ok && pass2;

  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error('race-test could not run:', err.message);
  process.exit(1);
});
