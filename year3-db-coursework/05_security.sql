-- =====================================================================
-- Файл 05: ролі та права доступу (розділ 5.8 методичних рекомендацій)
-- Запускати після 02_logic.sql (потрібні процедури) від імені власника схеми.
--
-- Модель доступу побудовано за ролями предметної області:
--   rental_operator — оформлює видачу/повернення, реєструє клієнтів;
--   rental_manager  — керує цінами, знижками, блокуванням, обслуговуванням;
--   rental_analyst  — лише читає, без персональних даних клієнтів.
-- Ролі — групові (NOLOGIN). Для реальних користувачів:
--   CREATE ROLE ivan LOGIN PASSWORD '...'; GRANT rental_operator TO ivan;
-- (паролі в скриптах не зберігаємо).
--
-- Ключова ідея: оператор НЕ має прямих INSERT/UPDATE на rentals,
-- rental_items, payments, tools.status. Усі зміни проходять через процедури
-- SECURITY DEFINER, які гарантують узгодженість (застава, статус, платежі).
-- =====================================================================

-- Ролі належать кластеру, а не базі: вони переживають DROP SCHEMA / DROP DATABASE,
-- тому створення зроблено повторно запускним.
DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['rental_operator', 'rental_analyst', 'rental_manager'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END;
$$;

-- Щоб власник міг перевіряти права командою SET ROLE (див. 06_tests.sql)
GRANT rental_operator, rental_analyst, rental_manager TO CURRENT_USER;

-- Починаємо з повного закриття доступу для PUBLIC
REVOKE ALL ON SCHEMA rental FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA rental FROM PUBLIC;
REVOKE ALL ON ALL ROUTINES  IN SCHEMA rental FROM PUBLIC;

GRANT USAGE ON SCHEMA rental TO rental_operator, rental_analyst, rental_manager;

-- ---------------------------------------------------------------------
-- Оператор
-- ---------------------------------------------------------------------
GRANT SELECT ON rental.tools, rental.categories, rental.suppliers,
                rental.customers, rental.rentals, rental.rental_items,
                rental.payments,
                rental.v_active_rentals, rental.v_tool_last_rental
      TO rental_operator;
GRANT SELECT (id, full_name, position, active) ON rental.employees TO rental_operator;

-- Реєстрація та редагування контактів клієнта (але не знижка і не блокування)
GRANT INSERT (full_name, phone, email) ON rental.customers TO rental_operator;
GRANT UPDATE (full_name, phone, email) ON rental.customers TO rental_operator;

GRANT EXECUTE ON PROCEDURE
      rental.open_rental(integer, integer, integer[], timestamptz, timestamptz, text, integer),
      rental.return_tool(integer, integer, timestamptz, text, boolean)
      TO rental_operator;
GRANT EXECUTE ON FUNCTION
      rental.billed_days(timestamptz, timestamptz),
      rental.rental_amount(integer, timestamptz),
      rental.late_fee(integer, timestamptz, numeric)
      TO rental_operator, rental_analyst;

-- ---------------------------------------------------------------------
-- Менеджер: усе, що оператор, плюс ціни, знижки, обслуговування, аудит
-- ---------------------------------------------------------------------
GRANT rental_operator TO rental_manager;

GRANT INSERT ON rental.tools, rental.categories, rental.suppliers TO rental_manager;
GRANT UPDATE (daily_price, deposit_amount, name, brand, model) ON rental.tools TO rental_manager;  -- НЕ status
GRANT UPDATE (discount_percent, is_blocked) ON rental.customers TO rental_manager;
GRANT SELECT ON rental.maintenance_log, rental.tool_audit, rental.v_monthly_revenue TO rental_manager;
GRANT SELECT ON rental.employees TO rental_manager;
GRANT EXECUTE ON PROCEDURE
      rental.start_maintenance(integer, integer, timestamptz, text, bigint),
      rental.finish_maintenance(bigint, integer, timestamptz, numeric, integer)
      TO rental_manager;

-- ---------------------------------------------------------------------
-- Аналітик: лише читання; персональні дані клієнтів приховано
-- (колонкові права: немає full_name, phone, email)
-- ---------------------------------------------------------------------
GRANT SELECT ON rental.tools, rental.categories, rental.suppliers,
                rental.rentals, rental.rental_items, rental.payments,
                rental.maintenance_log, rental.tool_audit,
                rental.v_tool_last_rental, rental.v_monthly_revenue
      TO rental_analyst;
GRANT SELECT (id, discount_percent, is_blocked, registered_at) ON rental.customers TO rental_analyst;
GRANT SELECT (id, position, active) ON rental.employees TO rental_analyst;
-- v_active_rentals містить ПІБ і телефони, тому аналітику НЕ видається.

-- ---------------------------------------------------------------------
-- Матриця доступу (таблиця 5.6): формується із системного каталогу.
--   table_wide   — право на всю таблицю;
--   some_columns — право хоча б на частину стовпців (колонкові GRANT).
-- ---------------------------------------------------------------------
SELECT t.relname AS object,
       r.rolname AS role,
       p.priv    AS privilege,
       has_table_privilege(r.rolname, t.oid, p.priv)      AS table_wide,
       CASE WHEN p.priv = 'DELETE' THEN false   -- колонкових прав DELETE не існує
            ELSE has_any_column_privilege(r.rolname, t.oid, p.priv) END AS some_columns
FROM pg_roles AS r
CROSS JOIN pg_class AS t
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p(priv)
WHERE r.rolname IN ('rental_operator', 'rental_analyst', 'rental_manager')
  AND t.relnamespace = 'rental'::regnamespace
  AND t.relkind IN ('r', 'v')
  AND t.relname IN ('tools', 'customers', 'rentals', 'payments', 'tool_audit', 'v_monthly_revenue')
ORDER BY t.relname, r.rolname, p.priv;
