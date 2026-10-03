#!/usr/bin/env bash
# Applies db/migrations/V*.sql in name order as the SURAKSHA user.
# Stops at the first failing file.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite "/" arguments into Windows paths

cd "$(dirname "$0")/migrations"

for f in V*.sql; do
  echo "================ $f"
  if ! docker exec -i suraksha-oracle sqlplus -S -L suraksha/suraksha@//localhost:1521/FREEPDB1 < "$f"; then
    echo "!!!!!!!!!!!!!!!! FAILED: $f  (fix it, run db/reset.sh, then run this again)"
    exit 1
  fi
done
echo "All migrations applied."