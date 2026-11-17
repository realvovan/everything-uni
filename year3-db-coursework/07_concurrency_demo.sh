#!/usr/bin/env bash
# =====================================================================
# Automated concurrency demo: two independent psql processes
# (= two database connections). Reproduces scenarios 1 and 2 from
# 07_concurrency.sql.
# Connection parameters are the standard PGHOST, PGPORT, PGUSER, PGDATABASE
# variables (password via ~/.pgpass / pgpass.conf or PGPASSWORD; do not
# store it in this file).
# Run:  bash 07_concurrency_demo.sh
# Demo data (tool T-DEMO and its rentals) is deleted at the end.
# =====================================================================
set -u
export PGCLIENTENCODING=UTF8
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=rental_db
export PGPASSWORD=123456789
PSQL="psql -X -q -v ON_ERROR_STOP=1"
LOG=$(mktemp -d)

TOOL_ID=$($PSQL -tA -c "INSERT INTO rental.tools (inventory_code, name, category_id, daily_price, deposit_amount, purchase_date)
                        VALUES ('T-DEMO', 'Demo tool', 1, 100, 500, '2026-11-01') RETURNING id")
echo "Demo tool id=$TOOL_ID"

now_s() { date +%s.%N; }
elapsed() { awk "BEGIN{printf \"%.2f\", $2 - $1}"; }

echo
echo "=== SCENARIO 1: SELECT ... FOR UPDATE blocks UPDATE ==="
# Session A: locks the row for 5 s, then ROLLBACK
( $PSQL -c "BEGIN; SELECT id FROM rental.tools WHERE id = $TOOL_ID FOR UPDATE; SELECT pg_sleep(5); ROLLBACK;" \
    > "$LOG/s1_A.log" 2>&1 ) &
sleep 1
# Session B: tries to update the same row with a 2 s lock_timeout
T0=$(now_s)
$PSQL -c "BEGIN; SET LOCAL lock_timeout = '2s'; UPDATE rental.tools SET daily_price = daily_price + 1 WHERE id = $TOOL_ID; ROLLBACK;" \
    > "$LOG/s1_B.log" 2>&1
T1=$(now_s)
echo "Session B waited $(elapsed "$T0" "$T1") s. Response:"
sed 's/^/   /' "$LOG/s1_B.log"
wait

echo
echo "=== SCENARIO 2: double checkout of the same tool ==="
# Session A: opens a rental and holds the transaction for 6 s
( $PSQL -c "BEGIN;
            CALL rental.open_rental(1, 1, ARRAY[$TOOL_ID], now(), now() + interval '2 days', 'cash', NULL);
            SELECT pg_sleep(6);
            COMMIT;" > "$LOG/s2_A.log" 2>&1 ) &
sleep 1.5
# Observer: who is waiting on what
( sleep 2; $PSQL -c "SELECT pid, state, wait_event_type, wait_event, left(query, 50) AS query
                     FROM pg_stat_activity
                     WHERE datname = current_database() AND wait_event_type = 'Lock'" \
    > "$LOG/s2_watch.log" 2>&1 ) &
# Session B: the same tool for a different customer
T0=$(now_s)
$PSQL -c "CALL rental.open_rental(2, 2, ARRAY[$TOOL_ID], now(), now() + interval '2 days', 'cash', NULL);" \
    > "$LOG/s2_B.log" 2>&1
T1=$(now_s)
wait
echo "Observer (pg_stat_activity) while B was waiting:"; sed 's/^/   /' "$LOG/s2_watch.log"
echo "Session B waited $(elapsed "$T0" "$T1") s and got:"
sed 's/^/   /' "$LOG/s2_B.log"
echo "Active rentals of the tool after the experiment (expected: 1):"
$PSQL -tA -c "SELECT COUNT(*) FROM rental.rental_items WHERE tool_id = $TOOL_ID AND returned_at IS NULL"

echo
echo "=== Cleaning up demo data ==="
$PSQL <<SQL
CREATE TEMP TABLE demo_rentals AS SELECT rental_id FROM rental.rental_items WHERE tool_id = $TOOL_ID;
DELETE FROM rental.payments     WHERE rental_id IN (SELECT rental_id FROM demo_rentals);
DELETE FROM rental.rental_items WHERE tool_id = $TOOL_ID;
DELETE FROM rental.rentals      WHERE id IN (SELECT rental_id FROM demo_rentals);
DELETE FROM rental.tools        WHERE id = $TOOL_ID;
SQL
echo "Done. Session logs: $LOG"