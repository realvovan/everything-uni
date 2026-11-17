-- =====================================================================
-- File 09: verification queries for checking a restore (section 5.10)
-- Run on the SOURCE database and on the RESTORED database; compare outputs (diff).
-- All values are deterministic (no now() and no random numbers).
-- =====================================================================
\echo '== 1. Row counts per table =='
SELECT table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text AS row_count
FROM information_schema.tables
WHERE table_schema = 'rental' AND table_type = 'BASE TABLE'
ORDER BY table_name;

\echo '== 2. Schema objects =='
SELECT 'constraints ' || contype::text AS object_kind, COUNT(*) FROM pg_constraint
 WHERE connamespace = 'rental'::regnamespace GROUP BY contype
UNION ALL SELECT 'indexes',  COUNT(*) FROM pg_indexes WHERE schemaname = 'rental'
UNION ALL SELECT 'views',    COUNT(*) FROM pg_views   WHERE schemaname = 'rental'
UNION ALL SELECT 'functions',  COUNT(*) FROM pg_proc WHERE pronamespace = 'rental'::regnamespace AND prokind = 'f'
UNION ALL SELECT 'procedures', COUNT(*) FROM pg_proc WHERE pronamespace = 'rental'::regnamespace AND prokind = 'p'
UNION ALL SELECT 'triggers', COUNT(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE NOT t.tgisinternal AND c.relnamespace = 'rental'::regnamespace
ORDER BY 1;

\echo '== 3. Data checksums =='
SELECT kind, COUNT(*) AS n, SUM(amount) AS total FROM rental.payments GROUP BY kind ORDER BY kind;
SELECT status, COUNT(*) FROM rental.tools GROUP BY status ORDER BY status;
SELECT md5(string_agg(r.id || ':' || r.customer_id || ':' || r.status || ':' || r.rented_at::text,
                      ',' ORDER BY r.id)) AS rentals_checksum
FROM rental.rentals AS r;

\echo '== 4. Results of the main queries and functions =='
SELECT rental.rental_amount(3) AS amount_r3, rental.late_fee(3) AS fee_r3, rental.billed_days('2026-10-01 10:00+03', '2026-10-02 10:01+03') AS days;
SELECT c.full_name, COUNT(DISTINCT r.id) AS rentals_count, SUM(p.amount) AS paid_total
FROM rental.customers AS c
JOIN rental.rentals  AS r ON r.customer_id = c.id
JOIN rental.payments AS p ON p.rental_id = r.id AND p.kind IN ('rental', 'penalty')
GROUP BY c.id, c.full_name HAVING COUNT(DISTINCT r.id) >= 2 ORDER BY paid_total DESC;
SELECT * FROM rental.v_tool_last_rental ORDER BY tool_id;

\echo '== 5. IDENTITY counters (next ids must not conflict) =='
SELECT sequencename, last_value FROM pg_sequences WHERE schemaname = 'rental' ORDER BY sequencename;

\echo '== 6. Role privileges (must match if the roles exist in the cluster) =='
SELECT has_table_privilege('rental_analyst',  'rental.tools',   'SELECT') AS analyst_select_tools,
       has_table_privilege('rental_analyst',  'rental.tools',   'INSERT') AS analyst_insert_tools,
       has_table_privilege('rental_operator', 'rental.rentals', 'INSERT') AS operator_insert_rentals,
       has_function_privilege('rental_operator',
           'rental.open_rental(integer, integer, integer[], timestamptz, timestamptz, text)', 'EXECUTE') AS operator_exec_open_rental;

\echo '== 7. Constraints and trigger still work after the restore (result is a message) =='
-- The checks use UPDATE rather than INSERT: a failed INSERT "burns" an IDENTITY value
-- and would change the counters from step 5, breaking the comparison of the source
-- and restored databases.
DO $$
BEGIN
    BEGIN
        UPDATE rental.tools SET inventory_code = 'T-001' WHERE inventory_code = 'T-002';
        RAISE EXCEPTION 'FAIL: duplicate inventory_code was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'OK: UNIQUE(inventory_code) worked';
    END;
    BEGIN
        UPDATE rental.tools SET status = 'available' WHERE inventory_code = 'T-016';
        RAISE EXCEPTION 'FAIL: retired -> available transition was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
        RAISE NOTICE 'OK: status transition trigger worked';
    END;
END;
$$;