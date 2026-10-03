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
|  |  |

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
