# Your migrations go here

`db/init/01_schema.sql` is the schema as it came out of the legacy system. Treat
it as read-only history.

Put your changes here as numbered scripts, for example:

```
db/migrations/V001__constraints_and_indexes.sql
db/migrations/V002__normalise_premium_columns.sql
db/migrations/V003__record_payment.sql
db/migrations/V004__policy_status_view.sql
```

Two things we care about:

1. **They must actually run** against the seeded database, in order, from a
   clean `docker compose up`. Say in `NOTES.md` exactly how to run them.
2. **Some of them will fail the first time.** That is the point. The legacy data
   does not satisfy the constraints a sane schema would have. Decide what to do
   about each conflict — clean it, quarantine it, relax the constraint — and
   write down why you chose that. We are more interested in the reasoning than
   in a green run.

Running a script by hand:

```bash
docker exec -i suraksha-oracle sqlplus -S suraksha/suraksha@//localhost:1521/FREEPDB1 \
  < db/migrations/V001__constraints_and_indexes.sql
```
