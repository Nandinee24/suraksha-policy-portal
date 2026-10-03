#!/usr/bin/env bash
# Drops the SURAKSHA schema and reloads the legacy schema + seed (as SYSDBA),
# giving a clean starting point for db/migrate.sh. Stop the backend first.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

echo ">> dropping SURAKSHA schema"
docker exec -i suraksha-oracle sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CONTAINER = FREEPDB1;
DROP USER SURAKSHA CASCADE;
EXIT
SQL

echo ">> reloading legacy schema and seed"
docker exec -i suraksha-oracle sqlplus -S / as sysdba < init/01_schema.sql > /dev/null
docker exec -i suraksha-oracle sqlplus -S / as sysdba < init/02_seed.sql   > /dev/null
echo "Reset complete. Now run: bash db/migrate.sh"