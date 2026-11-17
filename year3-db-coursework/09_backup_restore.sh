#!/usr/bin/env bash
# =====================================================================
# File 09: backup and restore VERIFICATION (section 5.10)
# A backup is considered usable only after it has been restored into a
# separate database and the control results have been compared (09_verify.sql).
#
# User is fixed to "postgres" and the source database to "rental_db" (see variables below).
# Other connection parameters: PGHOST, PGPORT (password: ~/.pgpass / pgpass.conf or PGPASSWORD).
# The restore database name can be changed:  RESTORE_DB=my_db_restore bash 09_backup_restore.sh
# WARNING: the target database RESTORE_DB will be DROPPED and created again.
# A logical backup (pg_dump) stores one database, not the whole cluster: roles
# (CREATE ROLE) are not part of the dump and must exist in the cluster before
# access privileges are restored.
# =====================================================================
set -euo pipefail
export PGCLIENTENCODING=UTF8
export PGUSER=postgres   # all psql/pg_dump/pg_restore/createdb/dropdb calls run as this user
export PGPASSWORD=123456789
SRC_DB=rental_db         # source database

RESTORE_DB=${RESTORE_DB:-rental_restore}
DUMP=${DUMP:-rental_db.dump}
OUT=${OUT:-.}

echo "== Tool versions (record them in the report) =="
pg_dump --version
pg_restore --version
psql -X -At -d "$SRC_DB" -c "SELECT version()"

echo "== 1. Control results of the SOURCE database =="
psql -X -q -v ON_ERROR_STOP=1 -d "$SRC_DB" -f 09_verify.sql > "$OUT/verify_source.txt" 2>&1

echo "== 2. Backup (custom format, schema rental only) =="
pg_dump -Fc -n rental -f "$DUMP" "$SRC_DB"
ls -l "$DUMP"
pg_restore -l "$DUMP" | grep -v '^;' | sed -n '1,12p'   # first objects in the dump (sed, not head: avoids SIGPIPE with pipefail)

echo "== 3. Restore into a separate empty database $RESTORE_DB =="
dropdb --if-exists "$RESTORE_DB"
createdb "$RESTORE_DB"
pg_restore --exit-on-error --no-owner -d "$RESTORE_DB" "$DUMP"

echo "== 4. Control results of the RESTORED database =="
psql -X -q -v ON_ERROR_STOP=1 -d "$RESTORE_DB" -f 09_verify.sql > "$OUT/verify_restored.txt" 2>&1

echo "== 5. Comparison =="
if diff -u "$OUT/verify_source.txt" "$OUT/verify_restored.txt"; then
    echo "RESULT: restore successful - all control results match."
else
    echo "RESULT: DIFFERENCES FOUND (see diff above)." >&2
    exit 1
fi