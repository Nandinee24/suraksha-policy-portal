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

Start the database over (stop the backend first, it holds connections):

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

_Not built yet. RECORD_PAYMENT is the next step._

Ready in the schema already:
- Unique key on `IDEMPOTENCY_KEY`, so the same key can't create two payments.
- Unique `(POLICY_ID, COVERS_DUE_DATE)`, so the same instalment can't be paid twice.

## Idempotency

_Not built yet._ The key will be enforced inside RECORD_PAYMENT, backed by the unique
constraint on `PAYMENTS.IDEMPOTENCY_KEY`.

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
| 5013 is ACTIVE but has no next due date. 5011/5012 (surrendered/matured) have no dates | Left as-is. Status can't be calculated for them (to handle in the status view). |
| Partial payments accepted by legacy: 5041 (₹1,200.10 + ₹1,200.20 vs ₹3,200), 5061 (₹9,000 vs ₹18,000) | Kept as history. New payments must match the premium exactly (R5). |
| 5023/5024: paid on the last grace day at 19:00 and 18:00 UTC, i.e. 00:30 IST (late) and 23:30 IST (on time) | Shows why grace must be checked in IST, not UTC (R3). |
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

## Not done / next

- Rules package: IST "today", grace periods, month-end date maths.
- `V_POLICY_STATUS` view (PAID / DUE / IN_GRACE / LAPSED).
- `RECORD_PAYMENT` procedure (exact amount, revival window, locking, idempotency) and its tests.
- Backend endpoints and error mapping.
- Frontend list, detail and payment form.
- REVIEW.md.

## AI usage

- **Claude (Claude Code)**:
  - reviewed the starter repo and the assignment
  - helped profile the seed data and find the data problems
  - planned the work
  - drafted the migration SQL and the `migrate.sh` / `reset.sh` scripts
- **What I did myself:** read every script, ran each migration, checked every error
  against the data, and chose how to handle each case.
