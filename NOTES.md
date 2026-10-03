# NOTES

Replace the prompts under each heading. Bullet points are fine — this does not
need to be an essay. Say what you actually did, including what you did not
finish.

---

## How to run this

From a clean clone, the exact commands. Include how to run your migrations.

```bash
# 1. Database - first start takes a few minutes
docker compose up -d
docker compose logs -f oracle      # wait for "DATABASE IS READY TO USE!", then Ctrl+C
```
```
# 2. Migrations
#    (to be added)

```
```
# 3. Backend - http://localhost:3001
cd backend
cp .env.example .env
npm install
npm run dev
```
```
# 4. Frontend - http://localhost:5173 (separate terminal)
cd frontend
npm install
npm run dev
```

## Schema changes

What you added and why. For each index, the query it serves.

| Change | Why |
|---|---|
|  |  |

## Concurrency

What stops two simultaneous payments on the same policy from both succeeding?
How did you test it?

## Idempotency

Where is the key enforced, and what does a repeat request return?

## Data issues

Anything that looked wrong in the legacy data, and what you did about it.
If a migration of yours failed on the existing rows, say so and say how you
resolved it.

| What you found | What you did |
|---|---|
| PREMIUM_MODE has 25 spellings for 4 modes, plus SINGLE (5018), which is not an R1 mode | |
| PREMIUM_AMOUNT is free text in about 15 formats; 5014 is NULL, 5015 is 0, 5016 is −2,500 | |
| Policy 5021 points to customer 999999, which doesn't exist | |
| Payment 700469 belongs to policy 888888, which doesn't exist | |
| Idempotency key `BR-RETRY-7C41E9AA` was used twice | |
| Policy 5034 still shows its next due date as yesterday | |
| 5013 is ACTIVE but has no next due date. 5011/5012 (surrendered/matured) have no dates. | |
| Partial payments accepted by legacy: 5041 (₹1,200.10 + ₹1,200.20 vs ₹3,200), 5061 (₹9,000 vs ₹18,000). | |
| 5023/5024: payments on the last grace day at 19:00 and 18:00 UTC, i.e. 00:30 IST (late) and 23:30 IST (on time). | |
| `LEGACY_STATUS` is unreliable: ACTIVE / active / IN FORCE even for policies 800+ days overdue. | |
| 1152/1153 share the dummy PAN `ABCDE1234F`, both named Rajesh Patel (likely a duplicate customer). | |
| Names stored inconsistently (`RAJESH PATEL`, `rAJESH  mehta`, extra spaces); 1155 is in Gujarati script. | |

## Decisions and trade-offs

Anywhere the requirements were ambiguous and you had to choose. Also anywhere
you knowingly took a shortcut.

## Not done / next

What you would do with another day.

## AI usage

Which tools, and for which parts. Be specific — "Claude for the React list
component and the SQL pagination, PL/SQL written by hand" is the level of detail
we are after. This is not a trick question and there is no penalty for using AI
tools; there is one for not being able to explain your own code.
