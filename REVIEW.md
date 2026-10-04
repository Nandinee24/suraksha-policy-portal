# Code review — `legacy/paymentService.js`

Severity: `Critical` (money, data loss, security) · `High` · `Medium` · `Low`.
Worst first. Where the legacy data shows the bug has already happened, I say so.

---

### 1. Premium mode compared to `'M'`, `'Q'`, `'H'` only; everything else gets a year

**Severity:** Critical

**What:** Lines 73–79. The due date moves 30/90/180 days only if `PREMIUM_MODE` is
exactly `'M'`, `'Q'` or `'H'`. Any other value falls through to 365 days.

**Why it matters in production:** The real data has 25 spellings (`Mly`, `MONTHLY`,
`mth`, `quarterly`, `HALF-YEARLY`…). **110 of the 129 non-yearly policies** don't match.
A customer pays one monthly premium of ₹2,000 and the system moves their due date a
whole year ahead. The policy shows as paid, nobody chases the next 11 premiums, and the
company carries the risk for free. Nothing errors, so nobody notices.

**Fix:** Store the mode as a checked code (`Y/H/Q/M`), mapped once from the legacy text.
Reject unknown modes instead of defaulting. (Done in V020.)

---

### 2. `parseFloat` on a text premium: ₹4 accepted as ₹4,200

**Severity:** Critical

**What:** Line 53, `parseFloat(row[4])`, then the comparison on line 58.

**Why it matters in production:** The premium column is free text.
- `parseFloat("4,200.00")` is **4**, since it stops at the comma. A payment of ₹4 passes, and the real ₹4,200 is refused. 43 policies have comma premiums.
- `"Rs. 24,000.00"` and `"INR 3,200.00"` give `NaN`, so those **42 policies can never be paid** at the counter. The clerk sends the customer away, and the policy drifts into lapse.
- A premium of `"0"` (policy 5015) accepts a ₹0 payment and still moves the due date.

**Fix:** Keep the premium as `NUMBER(12,2)` and compare money in the database, not with
JS floats and `!=`. (Done in V030.)

---

### 3. Double charging: duplicate check and insert are not atomic

**Severity:** Critical

**What:** Lines 37–43 check "has this key been used?" and lines 83–88 insert later.
Nothing locks the policy and there's no unique constraint on the key.

**Why it matters in production:** A double-click or network retry sends two requests.
Both run the check before either inserts, both see "not used", and **both charge the
customer**. This has already happened: policy 5034, key `BR-RETRY-7C41E9AA`, two
₹36,000 payments 3 seconds apart. Two clerks with different keys on the same policy also
both succeed: they read the same due date, so the customer pays twice for one instalment.

**Fix:** Unique constraint on the key, plus a row lock on the policy (`SELECT … FOR
UPDATE`) in one transaction. (Done in V050 + `RECORD_PAYMENT`; proven with a two-session test.)

---

### 4. Insert and update are two separate commits

**Severity:** Critical

**What:** Lines 83–94. The payment insert and the due-date update each use `autoCommit: true`.

**Why it matters in production:** If the process crashes, the DB connection drops or the
update fails between the two, the money is recorded but the due date never moves. The
customer has paid but the screen says *In grace*, then *Lapsed*. The next payment covers
the same instalment again. The legacy data has policies in exactly this state (5023,
5024, 5034: a payment exists but the due date was never moved). This bug is one way
that can happen.

**Fix:** One transaction for both statements, committed once. (Done: one PL/SQL call.)

---

### 5. SQL injection

**Severity:** Critical

**What:** User input is pasted into SQL:
- `idemKey` on line 38 (it comes from a request header)
- `policyId` on line 47
- `search` on lines 109–110

**Why it matters in production:** Anyone who can send a request can read or change any
table. A key like `x' OR '1'='1` makes every payment look like a duplicate, so nobody can
pay. A crafted `search` can pull every customer's PAN, mobile and email. It also stops
Oracle reusing parsed statements, so every call is parsed again.

**Fix:** Bind variables everywhere (`:key`, `:id`), which the file already does for the
INSERT on line 85.

---

### 6. Connections leak on any error, and the pool has only 4

**Severity:** High

**What:** `conn.close()` is only called on the happy paths. There's no `try/finally`.
An unknown policy id makes `row` undefined, so line 53 throws a TypeError. Any DB error
also skips the close. The pool max is 4 (line 24).

**Why it matters in production:** After 4 errors there are no connections left. Every
following request waits for a connection, times out, and fails. **The whole branch
counter stops** until someone restarts the server, even for clerks doing nothing wrong.

**Fix:** `try { … } finally { conn.close() }`, a 404 for an unknown policy, and a sensible
pool size and queue timeout. (Done in `backend/src/db.js`.)

---

### 7. Grace period is wrong in three ways

**Severity:** High

**What:** Lines 64–70.

**Why it matters in production:**
- **Always 30 days.** Monthly policies should get 15 (R2), so lapsed monthly policies are treated as still in grace for 15 extra days.
- **The last day doesn't count.** `graceEnd` is midnight at the *start* of the last grace day, so a customer paying at 10 am on that day is told the policy has lapsed. R3 says the last day counts. That's a complaint, and a regulatory one.
- **Server time, not IST.** The server runs in UTC. From 00:00 to 05:30 IST it still thinks it's yesterday. The data shows the effect: policy 5023 was paid at 00:30 IST (late), 5024 at 23:30 IST (on time), and UTC dates would get both wrong.

**Fix:** Grace by mode; compare calendar dates in IST, inclusive of the last day.

---

### 8. Due dates move by fixed days, not calendar months

**Severity:** High

**What:** Lines 73–79 add 30/90/180/365 days.

**Why it matters in production:** 12 × 30 = 360, so a monthly due date drifts about
5 days earlier every year. After three years, a policy due on the 15th is due on the 1st.
Yearly policies slip a day in leap years. Customers get reminders and lapse on dates that aren't in their contract.

**Fix:** Add calendar months and keep the policy's due day, clipped at month end
(31 Jan → 28 Feb → 31 Mar). (Done in `POLICY_RULES.add_periods`.)

---

### 9. No revival: every lapsed policy is refused

**Severity:** High

**What:** Lines 67–70 refuse anything past grace.

**Why it matters in production:** R7 allows revival within 2 years by paying all pending
premiums. Customers who are entitled to keep their cover are turned away at the counter.
The company loses the policy and its future premiums, and the customer loses their insurance.

**Fix:** If lapsed and within 2 years of the first unpaid due date, accept exactly
N × premium and move the due date N periods.

---

### 10. Idempotency check isn't tied to the policy

**Severity:** High

**What:** Line 38 looks up the key across all policies, and line 42 returns that payment as success.

**Why it matters in production:** If a client reuses a key for a different policy, or a
bug reuses one, the clerk is told "payment recorded" for policy B while the money was
actually for policy A. Policy B is never paid and lapses, and the customer has a receipt
that says otherwise. The replay also doesn't return the new due date, so the caller gets
a different answer the second time.

**Fix:** Same key + same policy + same amount → return the first result. Otherwise refuse.

---

### 11. Random payment ids

**Severity:** Medium

**What:** Line 81, `Math.floor(Math.random() * 100000000)`.

**Why it matters in production:** With 100 million possible ids, there is a 50% chance of
a collision after only about 12,000 payments (the birthday problem). A collision makes
the INSERT fail with a primary-key error. Because of #6, that also leaks a connection.
The sequence `SEQ_PAYMENT_ID` already exists and is unused.

**Fix:** `SEQ_PAYMENT_ID.NEXTVAL`.

---

### 12. Dashboard list: one query per policy, no paging

**Severity:** Medium

**What:** `listPoliciesWithTotals`, lines 104–129.

**Why it matters in production:**
- **One extra query per policy:** 195 round trips for 194 policies, tens of thousands in a real branch. Meanwhile it holds 1 of the 4 pool connections, so loading the dashboard slows down payments.
- **No paging:** it loads everything every time.
- **Case-sensitive `LIKE`:** searching "rajesh" doesn't find "RAJESH PATEL", and `%` or `_` typed by the clerk act as wildcards.
- **Float totals:** money is added as JS floats (line 122), so totals can be off by paise.
- **Leaks on error,** same as #6.

**Fix:** One SQL query with `SUM … GROUP BY`, `UPPER()` on both sides, escaped wildcards,
`OFFSET/FETCH` paging, and bind variables.

---

### 13. Personal and financial data in logs

**Severity:** Medium

**What:** Line 34 logs every request (policy, amount, key). Line 51 logs the whole policy row.

**Why it matters in production:** Logs are copied, shipped and kept far longer than the
database, and many more people can read them. Policy and payment details in plain logs
are a data-protection problem (India's DPDP Act), and the logs become a second place to
leak from.

**Fix:** Log an id and the outcome only. Never log rows.

---

### 14. Payment time depends on the database server's clock zone

**Severity:** Medium

**What:** Line 85 stores `PAID_AT` as `SYSTIMESTAMP`.

**Why it matters in production:** `PAID_AT` is meant to be UTC. `SYSTIMESTAMP` is in the
database server's own timezone. It's UTC today only by luck. Move the DB to a server set
to IST and new payments are stored 5½ hours off, so "paid on the last day of grace"
decisions and reports quietly go wrong.

**Fix:** `SYS_EXTRACT_UTC(SYSTIMESTAMP)`.

---

### 15. Smaller problems

**Severity:** Low

- **Failures can't be told apart.** They return `{ ok: false, error: '…' }` with no code, so the HTTP layer can't send a proper status and the UI can't show the right message.
- **No input checks.** Amount, channel and key aren't validated (negative amounts, unknown channels, 500-character keys).
- **No policy state check.** A surrendered or matured policy has no due date, `new Date(null)` is 1970, and the clerk is told "Policy has lapsed", which is wrong and confusing. A single-premium policy would accept yearly payments forever.
- **No init guard.** If `init()` hasn't finished, `pool` is undefined and every call crashes.

---

## If you had to fix one thing before Monday

**#1: the premium mode mapping.**

- **It loses money on ordinary, correct use, every day.** Every monthly or quarterly
  payment on 110 policies gives a year of cover. No attacker or rare timing is needed,
  and nothing errors, so it won't be noticed.
- **It's a small, safe fix.** Map the spellings to four codes and refuse unknown ones.
- **The other Critical issues need more to happen:**
  - #2 shows up mostly as refused payments, which clerks will report.
  - #3 and #4 need a double-click or a crash at the wrong moment.
- **SQL injection (#5) is worse in theory.** If this endpoint is reachable from outside
  the branch network, I'd swap the order and fix #5 first.

Next, in the same week: #3 + #4 together (one transaction with a lock and a unique key),
then #5 and #6.
