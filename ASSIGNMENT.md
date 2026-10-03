# Policy Servicing Mini-Portal

---

## 1. The situation

Branch staff at **Suraksha Life Insurance** service policies at the counter all
day. Right now they do it in a tool nobody wants to touch any more. We are
rebuilding the smallest useful slice of it:

> Show me which policies have a premium due, which are in the grace period and
> which have lapsed — and let me record a payment.

You have a starter repo with Oracle in Docker, the legacy schema, and a dump of
legacy data. The data came out of a system that ran for eleven years. It is
messy in the way real data is messy.

---

## 2. Business rules

**R1 — Premium modes.** Yearly, Half-yearly, Quarterly, Monthly.

**R2 — Grace period.** 30 days after the due date for Yearly, Half-yearly and
Quarterly. **15 days for Monthly.**

**R3 — The last day counts.** A payment made on the final day of grace is on
time. The business runs in **IST (UTC+05:30)**. `PAYMENTS.PAID_AT` is stored in
**UTC**. Your server may well be running in UTC too.

**R4 — Status is derived, never stored.** Compute it; do not read
`LEGACY_STATUS`.

| Status     | Meaning                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `PAID`     | Nothing is due yet — the next due date is more than 30 days away        |
| `DUE`      | The next due date falls within the next 30 days and is not yet past     |
| `IN_GRACE` | The due date has passed but the policy is still within its grace period |
| `LAPSED`   | Grace has ended without payment                                         |

**R5 — Exact amounts only.** A payment must equal the modal premium exactly.
Partial payments and overpayments are rejected, with a reason the clerk can
read.

**R6 — One period forward.** A payment moves the next due date forward by
exactly one mode period. 31 January plus one month is 28 or 29 February — not
2 or 3 March. The same applies at every month-end.

**R7 — Revival window.** A lapsed policy can be revived only within **2 years**
of its first unpaid due date (`FIRST_UNPAID_DUE_DATE`). For this exercise,
"revive" just means accepting all pending dues in a single transaction. Outside
the window, the payment is refused.

**R8 — Never charge twice.** Branch staff double-click. Networks retry. Every
payment request carries an `Idempotency-Key` header. The same key must never
produce a second payment — and two simultaneous requests for the same policy
must not both succeed.

---

## 3. What to build

### A · Database (Oracle)

1. **Finish the schema.** `db/init/01_schema.sql` is what the legacy system
   left us. Decide what it is missing — keys, constraints, types, indexes — and
   add it as your own migration in `db/migrations/`. Do not edit the original
   files.

   > Some of your migrations will fail the first time you run them. That is
   > expected and it is informative. The legacy data does not satisfy the
   > constraints a sane schema would have. Deal with each conflict and write
   > down what you decided and why.

   For every index you add, say in `NOTES.md` which query it is for. An index
   with no query behind it counts against you.

2. **Write `RECORD_PAYMENT`** as a PL/SQL procedure (a stub signature is in the
   schema file — change it if you have a better one). It must enforce R5–R8
   **atomically**, and it must be correct when two sessions call it for the
   same policy at the same instant. Tell us in `NOTES.md` what stops the race,
   and how you convinced yourself it works.

3. **Write the derived-status query** (R4) as a view or a query, with
   server-side pagination and filtering. `V_POLICY_STATUS` is a stub.

### B · Backend (Node.js + `node-oracledb`)

| Endpoint                                        | Does                                                                                                                                    |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /policies?status=&search=&page=&pageSize=` | Filter by derived status; search policy number **or** customer name, case-insensitive; paginate in the database; return the total count |
| `GET /policies/:id`                             | Policy, customer, derived status, and payment history newest-first                                                                      |
| `POST /policies/:id/payments`                   | Records a payment via your procedure. Honours `Idempotency-Key`. Body: `{ "amount": 12500.00, "channel": "BRANCH" }`                    |

Also expected: bind variables everywhere, a connection pool used correctly
(including on the error path), and HTTP status codes that mean something —
a rejected business rule is not a 500. Return a machine-readable error code
alongside the human message.

### C · Frontend (React)

1. **Policy list** — status filter, search, server-side pagination. Status
   legible at a glance, and not conveyed by colour alone.
2. **Policy detail** — details, payment history, and a **Record Payment** form.
3. The form must be impossible to submit twice (double-click, Enter key, slow
   network) and must show the API's business-rule errors in language a branch
   clerk would understand.
4. Loading, empty and error states everywhere. Amounts formatted as INR.

Routing, state and styling are your call. A component library is fine. Plain
CSS is fine.

### D · Code review

`legacy/paymentService.js` is running in production today. **Do not fix it.**
Review it. In `REVIEW.md`, list what you find — what is wrong, why it matters
in production, and how you would fix it. What we are reading is the "why it
matters", not the label.

### E · `NOTES.md`

Fill in the template. Specifically:

- How to run your work, from zero.
- The decisions you made and what you traded away.
- **Anything you found odd in the data**, and what you did about it.
- What you did not get to, and what you would do with another day.
- **Your AI usage** — see below.

---

## 4. About AI tools

Use them. We do, every day. There is one condition and we take it seriously:

> **You must be able to explain and modify every line you submit.**

Tell us in `NOTES.md` which tools you used and for what.

## 5. Submitting

- A **Git repo** which includes teh completeed assignment.
- **Keep your real commit history.** Do not squash it into one commit. We look
  at how the work was built up, and a single "initial commit" tells us nothing.
  Messy, honest history is better than a tidy fake one.
- Everything must run from a clean clone with `docker compose up` plus whatever
  you document.
- `NOTES.md` and `REVIEW.md` completed.

## 6. Then what

A **60-minute call**. You share your screen, walk us through what you built,
and we ask about specific lines. Then we hand you a small change to make
**live** — something in the same shape as the rules above. We are not trying to
trip you up; it is just much easier to talk about code while it is running.

Please bring the environment you built this in, working.

## 7. If you get stuck

A blocked environment is not a signal about you. If Docker or Oracle will not
cooperate after ~30 minutes, email us — we would rather unblock you than have
you lose an evening to it.

If something in the rules above is ambiguous, **make a decision, write it down
in `NOTES.md`, and carry on.** Noticing the ambiguity is worth more to us than
guessing what we meant. Real requirements are like this.

Good luck. We are looking forward to seeing it.
