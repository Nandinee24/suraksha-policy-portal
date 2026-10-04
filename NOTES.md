# NOTES

---

## How to run this

Needs Docker Desktop, Node 18+, and a bash shell (Git Bash on Windows) for the `db/*.sh` scripts.

```bash
# 1. Database - first start takes a few minutes
docker compose up -d
docker compose logs -f oracle      # wait for "DATABASE IS READY TO USE!", then Ctrl+C

# 2. Migrations - applies db/migrations/V*.sql in order, stops at the first error
bash db/migrate.sh

# 3. Backend - http://localhost:3001
cd backend
cp .env.example .env
npm install
npm run dev

# 4. Frontend - http://localhost:5173 (separate terminal)
cd frontend
npm install
npm run dev
```

Start the database over. Close every other DB connection first (backend, DBeaver,
sqlplus): Oracle can't drop a user who is connected (ORA-01940).

```bash
bash db/reset.sh      # drops the schema, reloads db/init/01_schema.sql + 02_seed.sql
bash db/migrate.sh
```

- Migrations are not re-runnable. Oracle commits on every DDL, so a failed run
  leaves half the changes behind. Fix the file, reset, run again.
- `db/analysis/00.sql` has the read-only queries I used to find the data problems.
  Its output is in `00_profile_output.txt`.
- `db/analysis/02_verify_migrations.sql` checks the result of the migrations and
  tries bad inserts to prove each constraint blocks them (all rolled back):
  `docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 < db/analysis/02_verify_migrations.sql`
- `db/tests/test_policy_rules.sql` tests month maths, status boundaries and the seed
  cases. Prints PASS/FAIL, changes nothing:
  `docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 < db/tests/test_policy_rules.sql`
- `db/tests/test_record_payment.sql` tests every RECORD_PAYMENT rule and prints the
  message a clerk would see. Changes nothing:
  `docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 < db/tests/test_record_payment.sql`
- `db/tests/race_test.sh` runs two sessions at the same time (see Concurrency).
  It resets the database first and commits test payments:
  `bash db/tests/race_test.sh`
- API tests, with the backend running (they record payments, so reset afterwards):
  - `npm run api-check` (in `backend/`) checks every endpoint and error code over HTTP.
  - `npm run race-test` sends 10 payment requests at the same moment.

## Schema changes

Original files in `db/init` are untouched. All changes are in `db/migrations`.

| Change | Why |
|---|---|
| `PAYMENTS_QUARANTINE` table (V010) | Bad payment rows are moved here with a reason, never deleted |
| `POLICIES.MODE_CODE` Y/H/Q/M + check (V020) | Premium mode was free text with 25 spellings |
| `POLICIES.PREMIUM` NUMBER(12,2) + check > 0 (V030) | Premium was text like `Rs. 24,000.00`; exact-amount checks (R5) need a real number |
| Original `PREMIUM_MODE` / `PREMIUM_AMOUNT` kept | Audit trail: you can see what the legacy system said |
| NOT NULL on policy no, customer id, start date (V040) | Always filled; keep it that way |
| Policy no stored upper case, unique (V040) | No two policies with the same number |
| Check: policy no must be upper case, no spaces (V045) | Unique rule is case-sensitive; without this, `sl-…` could duplicate `SL-…` again |
| Foreign key policy → customer (V040) | A policy must belong to a customer |
| Check: first unpaid date ≤ next due date (V040) | The oldest unpaid due can't be after the next one |
| NOT NULL on all payment columns (V050) | Always filled |
| Foreign key payment → policy (V050) | A payment must belong to a policy |
| Unique `IDEMPOTENCY_KEY` (V050) | R8: one key = at most one payment |
| Unique `(POLICY_ID, COVERS_DUE_DATE)` (V050) | R8: one payment per instalment, even with two different keys |
| Checks: amount > 0, channel in a fixed list (V050) | Block bad values |
| Customer PAN upper case + format check; names trimmed (V060) | One format; garbage PANs blocked |
| `POLICY_RULES` package (V070) | Every rule in one place: IST today, grace days, month maths, status. The view and the payment procedure use the same code. |
| `POLICIES.DUE_DAY_ANCHOR` (V070) | Remembers the real due day, so 31 Jan → 28 Feb → 31 Mar (R6) |
| `APP_CLOCK` table (V070) | Empty in normal use. Tests set it to fake "today" |
| `V_POLICY_STATUS` view (V080, extended in V090) | Status calculated on every read, never stored (R4). Also shows amount due, instalments due and revival deadline for the payment screen |
| `PAYMENT_RULES` package (V090) | Revival deadline (R7), how many instalments are due, amount to collect |
| `PAYMENTS.NEXT_DUE_AFTER`, `INSTALMENTS` (V090) | So a repeated request can return exactly the first result |
| `RECORD_PAYMENT` procedure (V100) | Takes a payment: R5–R8 in one atomic call |

**Indexes, and the query each one serves:**

| Index | Query |
|---|---|
| `IX_POL_POLICY_NO` | Find a policy by its number. Also backs the unique policy-no rule |
| `IX_POL_CUSTOMER_ID` | Join policies to customers (list + detail). Also stops Oracle locking the whole POLICIES table when a customer row changes |
| Index behind `UQ_PAY_IDEM_KEY` | "Has this key been used?" lookup in RECORD_PAYMENT |
| Index behind `UQ_PAY_POLICY_DUE` | Payment history for a policy (`WHERE POLICY_ID = :id`). Also covers the payment → policy foreign key |

**Indexes I did not add, on purpose:**
- Name search: the search is `LIKE '%text%'`, which a normal index can't use. At real
  volume I'd use Oracle Text.
- `PAYMENTS(POLICY_ID, PAID_AT)`: the unique index above already finds a policy's few payments.

## Concurrency

What stops two payments on the same policy at the same moment:

1. **Row lock.** `SELECT … FOR UPDATE WAIT 5` on the policy. The second call waits until
   the first commits, so they run one after the other, never together.
2. **Expected due date (required).** The caller sends the due date the clerk saw. After
   waiting, the second call sees the date has moved and is refused (`STALE_DUE_DATE`).
   Without this, it would quietly pay the *next* instalment and both would succeed.
3. **Unique `(POLICY_ID, COVERS_DUE_DATE)`.** Last line of defence: the database itself
   refuses two payments for the same instalment.
4. **5-second limit.** A stuck transaction can't freeze the counter; the second clerk
   gets `POLICY_BUSY` and can retry.

How I tested it (`db/tests/race_test.sh`, two real sessions, B starts 1 s after A):

| Case | Result |
|---|---|
| Double-click: same key twice | A `RECORDED` payment 900000. B waited 2 s, then got `ALREADY_RECORDED`, same payment 900000 |
| Two clerks, different keys | A `RECORDED`. B waited, then got `STALE_DUE_DATE` |
| A holds its transaction for 8 s | B gave up after exactly 5 s with `POLICY_BUSY` |
| End check | exactly 1 new payment per policy |

Same check through the whole stack (`npm run race-test`, 10 HTTP requests at once):

| Case | Result |
|---|---|
| 10 × same key | 1 × `201`, 9 × `200 ALREADY_RECORDED`, all with the same payment id |
| 10 × different keys | 1 × `201`, 9 × `409 STALE_DUE_DATE` |

The test found a bug: Oracle 23 reports the lock timeout as ORA-00054, not ORA-30006.
The procedure only caught 30006, so the raw Oracle error leaked out. It now catches both.

## Idempotency

- **Where:** inside `RECORD_PAYMENT`, right after the row lock. Backed by the unique
  constraint on `PAYMENTS.IDEMPOTENCY_KEY`, so the key and the payment are saved together.
- **Why after the lock:** a duplicate request that was waiting then sees the first
  request's payment, instead of both seeing "key not used yet".
- **A repeat returns** `ALREADY_RECORDED` with the **first** payment id and next due date
  (stored on the payment in `NEXT_DUE_AFTER`). No second payment.
- **Same key, different policy or amount** → refused (`IDEMPOTENCY_KEY_REUSED`). Never
  answered with someone else's payment.
- **Only successful payments store a key.** A rejected request saved nothing, so trying it
  again is checked again from scratch.
- **Over HTTP:** the `Idempotency-Key` header is required (400 without it). First request
  gives `201`. A repeat gives `200` with the same body and the header `Idempotent-Replayed: true`.

## API

| Endpoint | Notes |
|---|---|
| `GET /policies?status=&search=&page=&pageSize=` | Filter, search and paging in the database; returns `items`, `total`, `totalPages`. Search ignores case and matches policy no or name. `%` and `_` are searched literally. `pageSize` max 100. |
| `GET /policies/:id` | Policy, status, amount to collect today, customer (PAN masked), payments newest first with IST times and a `paidLate` flag |
| `POST /policies/:id/payments` | Body `{ amount, channel, expectedDueDate }`, header `Idempotency-Key`. Calls `RECORD_PAYMENT` |

Every error looks like `{ "error": "AMOUNT_MISMATCH", "message": "Please collect exactly Rs. 2,000.00 …" }`.

| HTTP | Meaning | Codes |
|---|---|---|
| 400 | Fix the request | `VALIDATION_ERROR`, `IDEMPOTENCY_KEY_REQUIRED` |
| 404 | No such policy / route | `POLICY_NOT_FOUND`, `NOT_FOUND` |
| 409 | Clashed with another request or existing data: refresh or retry | `STALE_DUE_DATE`, `POLICY_BUSY`, `IDEMPOTENCY_KEY_REUSED`, `INSTALMENT_ALREADY_PAID` |
| 422 | Valid request, a business rule says no | `AMOUNT_MISMATCH`, `REVIVAL_WINDOW_EXPIRED`, `NOT_YET_DUE`, `POLICY_NOT_SERVICEABLE` |
| 503 | Database down or pool full | `DB_UNAVAILABLE` |
| 500 | Real bug (logged) | `INTERNAL` |

## Data issues

Several of my migrations failed the first time on this data. The error is noted next to each one.

| What I found | What I did |
|---|---|
| Premium mode in 25 spellings (`Yly`, `ANNUAL`, `mth`, `' Quarterly'`…) plus `SINGLE` on 5018, which is not one of the 4 modes | Mapped each spelling to Y/H/Q/M with a fixed list. NOT NULL failed (ORA-02296) because of 5018, so its mode is left empty and it can't take payments. Original text kept. |
| Premium amount as text in ~15 formats (`Rs.`, `INR`, commas, spaces) | Parsed into a number. The `Rs.` prefix is removed first, otherwise its dot breaks the number. |
| 5014 premium empty, 5015 is 0, 5016 is −2,500 | NOT NULL failed (ORA-02296). Set to empty, so these policies can't take payments. Did not guess: 5016 is probably a sign typo, but it's a money field. |
| 5019 and 5020 have the same policy no `SL-2024-000120` (different customers) | Unique rule failed (ORA-02299). Added it with `NOVALIDATE`: this pair stays, new duplicates are blocked. Didn't renumber, because the number is on the customer's documents. |
| My own check (`db/analysis/02_verify_migrations.sql`) found that a new lower-case `sl-2024-000101` still got past the unique rule. That's how the legacy duplicate happened. | Added a check forcing upper case (V045). |
| Policy 5021's customer (999999) doesn't exist | Foreign key failed (ORA-02298). Added it with `NOVALIDATE`. The policy stays visible and payable; it's still a real contract. |
| 5008/5009/5010: first unpaid date is after the next due date | Check failed (ORA-02293). Kept as-is: these are the 2-year revival test cases, and R7 says to measure from the first unpaid date. Check added with `NOVALIDATE`. |
| Payment 700469 (₹5,000) is for policy 888888, which doesn't exist | Foreign key failed (ORA-02298). Moved to quarantine (`ORPHAN_POLICY`) for finance to check. |
| Key `BR-RETRY-7C41E9AA` used twice, 3 seconds apart (700467/700468, policy 5034): a real double charge | Unique key failed (ORA-02299). Kept the first; moved the second to quarantine (`DUPLICATE_CHARGE_REFUND_DUE`). **The customer needs a refund.** |
| Policy 5034 was paid 9 days ago but still shows its next due date as yesterday | Left as-is. Status is calculated from the policy row (R4), not from payments. |
| 5013 is ACTIVE but has no next due date. 5011/5012 (surrendered/matured) have no dates | Left as-is. Shown with status `NOT_SERVICEABLE`. |
| Partial payments accepted by legacy: 5041 (₹1,200.10 + ₹1,200.20 vs ₹3,200), 5061 (₹9,000 vs ₹18,000) | Kept as history. New payments must match the premium exactly (R5). |
| 5023/5024: paid on the last grace day at 19:00 and 18:00 UTC, i.e. 00:30 IST (late) and 23:30 IST (on time) | Shows why grace must be checked in IST, not UTC (R3). |
| 5023/5024 also: a payment exists for the instalment, but the policy's due date was never moved | A new payment would pay the same instalment twice. RECORD_PAYMENT refuses it (`INSTALMENT_ALREADY_PAID`) and tells the clerk to refer it to servicing. |
| `LEGACY_STATUS` says ACTIVE / active / IN FORCE even for policies 800+ days overdue | Not used. Status is calculated (R4). |
| 1152/1153 share the dummy PAN `ABCDE1234F`, both "Rajesh Patel" (likely the same person twice) | PAN cleaned to one format. No unique rule on PAN and no merge: that's a KYC decision. |
| Names stored inconsistently (`RAJESH PATEL`, `rAJESH  mehta`, extra spaces); 1155 is in Gujarati | Extra spaces removed, casing kept. Search must ignore case. |
| Seed dates are relative to the container's clock, which is UTC. My first load ran at 02:48 IST, so all dates were one day off | Reloaded after 05:30 IST. "Today" must be calculated in IST, never with `SYSDATE`. |

## Decisions and trade-offs

- **Never delete or guess money data.** Bad payments go to quarantine; bad premiums are left empty.
- **Protect new data even if old data is dirty.** `ENABLE NOVALIDATE` keeps the legacy rows and still checks every new or changed row.
- **The original text columns are kept** next to the cleaned ones. Trade-off: two similar columns; the app uses only the new ones.
- **Orphan policy kept, orphan payment quarantined.** A policy is still a contract with premiums owed; a payment with no policy is unexplained money.
- **No data-issue table.** Each decision is written in the migration's comments and here. Trade-off: no follow-up queue for operations.
- **Migrations run with a small bash script, not Flyway.** Simple and easy to read. Trade-off: no partial re-runs; reset and run all.
- **`.gitattributes` forces LF line endings** on `.sql`/`.sh`. They run inside a Linux container; Windows CRLF breaks them.
- **"Today" is the IST date**, from one function. The container runs in UTC, so `SYSDATE` would be a day behind between 00:00 and 05:30 IST.
- **Status boundaries** (my reading of R4):
  - 30 days away = DUE ("PAID" says *more than* 30)
  - due today = DUE ("not yet past")
  - last day of grace = IN_GRACE (R3)
- **A fifth status, `NOT_SERVICEABLE`**, for policies with no valid mode, premium or due date (5011–5016, 5018). Putting them in PAID or LAPSED would be wrong, and `LEGACY_STATUS` can't be used.
- **Month maths uses an anchor day, not `ADD_MONTHS`.**
  - `ADD_MONTHS` turns 30 Apr into 31 May.
  - `+ INTERVAL '1' MONTH` crashes on 31 Jan.
  - Trade-off: the anchor comes from today's due date, so a policy really due on the 30th that currently sits on 28 Feb looks month-end.
- **Rules live in the database** (PL/SQL), not in Node, so the list and the payment check can't disagree.
- **Test clock in a table**, not a package variable: recompiling a package with state breaks pooled sessions (ORA-04068).
- **RECORD_PAYMENT signature changed:** added `P_EXPECTED_DUE`, required. It's what stops two clerks both succeeding (see Concurrency). Trade-off: the caller must send it.
- **Revival (R7) collects all pending premiums at once.** It's still an exact amount (N × premium), and the due date moves N periods. R5 says "the modal premium" and R6 says "one period", so I treat revival as the stated exception. Example: 5008 must pay 5 × ₹12,000 = ₹60,000.
- **Revival window is inclusive**, in calendar years (`first unpaid + 24 months`), not 730 days. Tested: 729 and 730 days revive, 731 is refused.
- **No advance payments.** If nothing is due yet (PAID), the payment is refused with the next due date. It also blocks a second click from paying next month. Trade-off: no prepaying at the counter.
- **No COMMIT inside the procedure.** The caller commits. If anything fails, the whole call rolls back, so the insert and update always happen together.
- **`PAID_AT` is written as UTC explicitly** (`SYS_EXTRACT_UTC`), not "whatever the server clock is".
- **Error codes -20001…-20010**, one per rule, each with a message a clerk can read. The backend maps them to HTTP codes.
- **Dates leave the API as `YYYY-MM-DD` text, made in SQL.** The Oracle driver turns a DATE into a JS Date in the server's timezone, which can show the previous day. Payment times are converted to IST in SQL and sent with `+05:30`.
- **Money is checked in the database only.** Node checks the amount's format (max 2 decimals, as text, so `2000.001` is rejected, not rounded), but the exact-premium rule is compared as an Oracle NUMBER. No float maths on money.
- **Two queries for the list (page + count)**, not `COUNT(*) OVER ()`, which gives no total on an empty page. Trade-off: one extra query.
- **No transaction wrapper in Node.** Every write is a single `RECORD_PAYMENT` call with `autoCommit`. Returning a connection to the pool rolls back anything left over, so a failed request never keeps a lock.
- **Pool waits at most 10 s** for a free connection, then answers 503, instead of hanging for the 60 s default.
- **PAN is masked** in the API (`AB******4F`). The counter doesn't need the full number.
- **Shutdown on SIGINT and SIGTERM.** Stop taking requests, finish running ones, close the pool.

## Not done / next

- Frontend list, detail and payment form.
- REVIEW.md.

## AI usage

- **Claude (Claude Code)**:
  - reviewed the starter repo and the assignment
  - helped profile the seed data and find the data problems
  - planned the work
  - drafted the migration SQL and the `migrate.sh` / `reset.sh` scripts
  - drafted the PL/SQL (`POLICY_RULES`, `PAYMENT_RULES`, `RECORD_PAYMENT`) and the database tests
  - drafted the backend (routes, validation, error mapping) and the API test scripts
- **What I did myself:** read every script, ran each migration, checked every error
  against the data, and chose how to handle each case.
