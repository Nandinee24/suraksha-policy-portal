# Suraksha Life · Policy Servicing Mini-Portal

**Read `ASSIGNMENT.md` first** — it has the task, the business rules and how we
assess it. This file is only about getting the thing running.

---

## What you need

- Docker with Docker Compose (the Oracle image needs ~4 GB free)
- Node.js 18 or newer
- On Apple Silicon: Docker Desktop's Rosetta emulation, or set
  `platform: linux/amd64` on the `oracle` service

## 1. Start the database

```bash
docker compose up -d
docker compose logs -f oracle
```

First start takes **3–6 minutes**. Wait for:

```
DATABASE IS READY TO USE!
```

The scripts in `db/init/` run automatically on that first start:

| File            | What it does                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| `01_schema.sql` | Creates the tables as they exist in the legacy system, plus stubs for the procedure and view you are asked to write |
| `02_seed.sql`   | Loads the legacy data dump — 155 customers, 194 policies, 472 payments                                              |

Connection details:

```
host     localhost
port     1521
service  FREEPDB1
user     suraksha
password suraksha
```

To start over from scratch (this wipes the data volume and re-runs the init
scripts):

```bash
docker compose down -v && docker compose up -d
```

## 2. Open a SQL prompt

```bash
docker exec -it suraksha-oracle sqlplus suraksha/suraksha@//localhost:1521/FREEPDB1
```

Or run a file:

```bash
docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 \
  < db/migrations/V001__constraints_and_indexes.sql
```

Quick check that the data is there:

```sql
SELECT COUNT(*) FROM POLICIES;   -- 194
SELECT COUNT(*) FROM PAYMENTS;   -- 472
SELECT COUNT(*) FROM CUSTOMERS;  -- 155
```

## 3. Backend

```bash
cd backend
cp .env.example .env
npm install
npm run dev
```

`node-oracledb` 6 runs in Thin mode, so you do **not** need Oracle Instant
Client installed.

Check it is talking to the database:

```bash
curl http://localhost:3001/health
```

## 4. Frontend

```bash
cd frontend
npm install
npm run dev
```

Opens on <http://localhost:5173>. Vite proxies `/api/*` to the backend on 3001.

---

## What is in the repo

```
db/init/01_schema.sql        legacy schema — read-only, do not edit
db/init/02_seed.sql          legacy data dump — read-only, do not edit
db/migrations/               your migrations go here
backend/                     Express + node-oracledb skeleton
frontend/                    Vite + React skeleton
legacy/paymentService.js     code to review (do NOT fix it)
ASSIGNMENT.md                the actual task
NOTES.md                     fill this in
REVIEW.md                    fill this in
```

## If something will not start

- **Oracle exits or restarts repeatedly** — usually memory. Give Docker at
  least 4 GB.
- **`ORA-12541` / connection refused** — the database is still initialising.
  Watch `docker compose logs -f oracle` for `DATABASE IS READY TO USE!`.
- **Init scripts did not run** — they only run when the data volume is empty.
  `docker compose down -v` and start again. To re-run them by hand they must go
  in as `SYSDBA`, because they switch into the PDB themselves:

  ```bash
  docker exec -i suraksha-oracle sqlplus -S / as sysdba < db/init/01_schema.sql
  docker exec -i suraksha-oracle sqlplus -S / as sysdba < db/init/02_seed.sql
  ```

- **Still stuck after 30 minutes** — email us. Fighting Docker is not part of
  the assessment and we would rather unblock you than have you lose an evening.
