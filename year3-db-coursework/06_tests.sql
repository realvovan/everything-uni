-- =====================================================================
-- Файл 06: тестові сценарії та протокол перевірки (розділ 5.12, додаток Е)
-- Запускати через psql від імені власника схеми після 01–03 і 05:
--     psql -d <база> -v ON_ERROR_STOP=1 -f 06_tests.sql
--
-- Як працює:
--   * увесь прогін виконується в одній транзакції і наприкінці скасовується
--     (ROLLBACK), тому тестові дані не залишаються в базі;
--   * pg_temp.run_test(код, опис, SQL, очікуваний SQLSTATE, роль) виконує команду,
--     перехоплює помилку і записує фактичний SQLSTATE ('OK' — помилки не було);
--   * pg_temp.check_value(код, опис, очікуване, запит) порівнює результат запиту
--     з очікуваним текстом;
--   * для ролей виконується SET LOCAL ROLE — це і є перевірка «від імені
--     звичайного користувача», а не власника.
-- Складні сценарії записано блоками DO з ASSERT: порушена перевірка дає код P0004
-- (текст ASSERT видно у стовпці detail — див. запит «Деталі збоїв» наприкінці).
-- Тести залежать від порядку: вони використовують стан, створений попередніми.
-- Коди помилок: 23505 unique_violation, 23503 foreign_key_violation,
--   23514 check_violation, 42501 insufficient_privilege, P0001 raise_exception.
-- =====================================================================
BEGIN;

CREATE TEMP TABLE test_log (
    seq         serial PRIMARY KEY,
    code        text NOT NULL,
    description text NOT NULL,
    expected    text NOT NULL,
    actual      text,
    detail      text,                                   -- текст помилки (для розбору збоїв)
    passed      boolean GENERATED ALWAYS AS (expected = actual) STORED
);

CREATE FUNCTION pg_temp.run_test(
    p_code text, p_descr text, p_sql text, p_expected text, p_role text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_actual text := 'OK';
    v_detail text;
BEGIN
    BEGIN                                   -- вкладена транзакція: помилка скасовує лише цей тест
        IF p_role IS NOT NULL THEN
            EXECUTE format('SET LOCAL ROLE %I', p_role);
        END IF;
        EXECUTE p_sql;
    EXCEPTION
        WHEN assert_failure THEN            -- OTHERS НЕ перехоплює ASSERT_FAILURE, тому окремий обробник
            v_actual := SQLSTATE;
            v_detail := SQLERRM;
        WHEN OTHERS THEN
            v_actual := SQLSTATE;
            v_detail := SQLERRM;
    END;
    RESET ROLE;
    INSERT INTO test_log (code, description, expected, actual, detail)
    VALUES (p_code, p_descr, p_expected, v_actual, v_detail);
END;
$fn$;

CREATE FUNCTION pg_temp.check_value(
    p_code text, p_descr text, p_expected text, p_query text
) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_actual text;
BEGIN
    BEGIN
        EXECUTE p_query INTO v_actual;
    EXCEPTION
        WHEN assert_failure THEN
            v_actual := 'ERR ' || SQLSTATE;
        WHEN OTHERS THEN
            v_actual := 'ERR ' || SQLSTATE;
    END;
    INSERT INTO test_log (code, description, expected, actual)
    VALUES (p_code, p_descr, p_expected, v_actual);
END;
$fn$;

-- Тихий режим psql на час викликів тестових функцій (кожен виклик друкує порожній рядок)
\pset tuples_only on
\pset format unaligned

-- Тихий режим psql на час викликів тестових функцій (кожен виклик друкує порожній рядок)
\pset tuples_only on
\pset format unaligned

-- ╔══════════════════ A. Коректна робота ═════════════════════════╗

SELECT pg_temp.run_test('T01', 'Позитивний: оператор оформлює оренду через процедуру (від імені rental_operator)',
  $q$CALL rental.open_rental(7, 1, ARRAY[2], now(), now() + interval '2 days', 'cash', NULL)$q$,
  'OK', 'rental_operator');

-- ╔══════════════════ B. Обмеження цілісності ═══════════════════╗

SELECT pg_temp.run_test('T02', 'BR01: повторний inventory_code',
  $q$INSERT INTO rental.tools (inventory_code, name, category_id, daily_price, purchase_date)
     VALUES ('T-001', 'Дублікат', 4, 100, '2026-01-01')$q$, '23505');

SELECT pg_temp.run_test('T03', 'BR02: ціна оренди 0 (CHECK, граничне значення)',
  $q$INSERT INTO rental.tools (inventory_code, name, category_id, daily_price, purchase_date)
     VALUES ('T-501', 'Нульова ціна', 4, 0, '2026-01-01')$q$, '23514');

SELECT pg_temp.run_test('T04', 'BR03: строк повернення не пізніше початку',
  $q$INSERT INTO rental.rentals (customer_id, employee_id, rented_at, due_at)
     VALUES (1, 1, '2026-11-10 10:00+02', '2026-11-10 10:00+02')$q$, '23514');

SELECT pg_temp.run_test('T05', 'BR05: видалення інструмента з історією оренд заборонено (RESTRICT)',
  $q$DELETE FROM rental.tools WHERE id = 1$q$, '23001');

SELECT pg_temp.run_test('T06', 'BR06: невірний формат телефону',
  $q$INSERT INTO rental.customers (full_name, phone) VALUES ('Тест', '12ab')$q$, '23514');

SELECT pg_temp.run_test('T07', 'BR07: знижка 31% понад ліміт 30% (граничне значення)',
  $q$UPDATE rental.customers SET discount_percent = 31 WHERE id = 1$q$, '23514');

SELECT pg_temp.run_test('T08', 'BR08: оренда довша за 60 діб (61 доба — порушення)',
  $q$CALL rental.open_rental(6, 1, ARRAY[13], now(), now() + interval '61 days', 'cash', NULL)$q$, '23514');

SELECT pg_temp.run_test('T09', 'BR08: рівно 60 діб — допустима межа',
  $q$INSERT INTO rental.rentals (customer_id, employee_id, rented_at, due_at)
     VALUES (6, 1, '2026-11-11 10:00+02', '2026-11-11 10:00+02'::timestamptz + interval '60 days')$q$, 'OK');

-- ╔══════════════════ C. Правила видачі та тригери ══════════════╗

SELECT pg_temp.run_test('T10', 'BR04: інструмент 2 уже в активній оренді (частковий UNIQUE-індекс)',
  $q$CALL rental.open_rental(6, 1, ARRAY[2], now(), now() + interval '1 day', 'cash', NULL)$q$, '23505');

SELECT pg_temp.run_test('T11', 'BR09 (тригер T1): видача інструмента, що на обслуговуванні (інструмент 4)',
  $q$CALL rental.open_rental(6, 1, ARRAY[4], now(), now() + interval '1 day', 'cash', NULL)$q$, 'P0001');

SELECT pg_temp.run_test('T12', 'BR10 (тригер T3): оренда для заблокованого клієнта (8)',
  $q$CALL rental.open_rental(8, 1, ARRAY[5], now(), now() + interval '1 day', 'cash', NULL)$q$, 'P0001');

SELECT pg_temp.run_test('T13', 'BR13 Атомарність: другий інструмент недоступний -> CALL скасовується повністю',
  $q$DO $do$
     DECLARE v_id integer; v_before integer;
     BEGIN
         SELECT COUNT(*) INTO v_before FROM rental.rentals;
         BEGIN
             CALL rental.open_rental(6, 1, ARRAY[6, 4], now(), now() + interval '1 day', 'cash', v_id);
             RAISE EXCEPTION 'очікувана помилка не виникла' USING ERRCODE = 'P0004';
         EXCEPTION WHEN raise_exception THEN
             NULL;   -- очікувана помилка тригера T1 (інструмент 4 на обслуговуванні)
         END;
         ASSERT (SELECT COUNT(*) FROM rental.rentals) = v_before, 'договір не мав зберегтися';
         ASSERT (SELECT status FROM rental.tools WHERE id = 6) = 'available', 'інструмент 6 мав лишитися вільним';
         ASSERT NOT EXISTS (SELECT 1 FROM rental.rental_items WHERE tool_id = 6 AND returned_at IS NULL),
                'активної позиції для інструмента 6 бути не повинно';
     END $do$$q$, 'OK');

-- ╔══════════════════ D. Повернення та розрахунки ═══════════════╗

SELECT pg_temp.run_test('T14', 'BR12: повернення раніше початку оренди (оренда 9)',
  $q$CALL rental.return_tool(9, 3, '2026-11-01 10:00+02', 'good', NULL)$q$, 'P0001');

SELECT pg_temp.run_test('T15', 'Повернення двох позицій оренди 9: оренда закривається, платежі й стани коректні',
  $q$DO $do$
     DECLARE v_closed boolean;
     BEGIN
         CALL rental.return_tool(9, 3, '2026-11-10 10:00+02', 'good', v_closed);
         ASSERT NOT v_closed, 'після першої позиції оренда має лишитися відкритою';
         CALL rental.return_tool(9, 15, '2026-11-10 10:00+02', 'good', v_closed);
         ASSERT v_closed, 'після останньої позиції оренда має закритися';
         ASSERT (SELECT status FROM rental.rentals WHERE id = 9) = 'closed', 'статус closed';
         ASSERT (SELECT string_agg(kind || ':' || amount, ',' ORDER BY id) FROM rental.payments WHERE rental_id = 9)
                = 'deposit:1800.00,rental:960.00,deposit_refund:1800.00', 'платежі: застава, 3 доби, повернення застави';
         ASSERT (SELECT COUNT(*) FROM rental.tools WHERE id IN (3, 15) AND status = 'available') = 2, 'інструменти вільні';
     END $do$$q$, 'OK');

SELECT pg_temp.check_value('T16', 'Граничні значення billed_days: рівно доба, доба й хвилина, нульовий інтервал',
  '1,2,1',
  $q$SELECT concat_ws(',',
            rental.billed_days('2026-10-01 10:00+03', '2026-10-02 10:00+03'),
            rental.billed_days('2026-10-01 10:00+03', '2026-10-02 10:01+03'),
            rental.billed_days('2026-10-01 10:00+03', '2026-10-01 10:00+03'))$q$);

-- ╔══════════════════ E. Обслуговування ═════════════════════════╗

SELECT pg_temp.run_test('T17', 'BR14 (тригер T4): повернення з оцінкою damaged -> ремонт, оренда 11 лишається відкритою',
  $q$DO $do$
     DECLARE v_closed boolean;
     BEGIN
         CALL rental.return_tool(11, 14, '2026-11-11 09:00+02', 'damaged', v_closed);
         ASSERT NOT v_closed, 'оренда 11 ще містить інструмент 10';
         ASSERT (SELECT status FROM rental.tools WHERE id = 14) = 'maintenance', 'інструмент 14 -> maintenance';
         ASSERT (SELECT COUNT(*) FROM rental.maintenance_log WHERE tool_id = 14 AND finished_at IS NULL) = 1,
                'має з''явитися один відкритий запис обслуговування';
     END $do$$q$, 'OK');

SELECT pg_temp.run_test('T18', 'BR15: другий відкритий запис обслуговування для інструмента 4 (частковий UNIQUE)',
  $q$INSERT INTO rental.maintenance_log (tool_id, started_at, description) VALUES (4, now(), 'Дублікат')$q$, '23505');

-- ╔══════════════════ F. Аудит і відкат ═════════════════════════╗

SELECT pg_temp.run_test('T19', 'BR11 (тригер T2): менеджер змінює ціну інструмента 5 -> запис аудиту; UPDATE без зміни запису не створює',
  $q$DO $do$
     BEGIN
         UPDATE rental.tools SET daily_price = 160 WHERE id = 5;
         ASSERT (SELECT COUNT(*) FROM rental.tool_audit
                 WHERE tool_id = 5 AND old_price = 150 AND new_price = 160) = 1, 'має бути запис аудиту 150 -> 160';
         UPDATE rental.tools SET daily_price = 160 WHERE id = 5;      -- без фактичної зміни
         ASSERT (SELECT COUNT(*) FROM rental.tool_audit WHERE tool_id = 5) = 1,
                'WHEN ... IS DISTINCT FROM: повторний запис не створюється';
     END $do$$q$, 'OK', 'rental_manager');

-- Відкат: результат усередині SAVEPOINT зберігаємо змінною psql (\gset), бо ROLLBACK TO
-- скасував би й записи протоколу, зроблені після SAVEPOINT.
SAVEPOINT sp_audit;
UPDATE rental.tools SET daily_price = daily_price + 10 WHERE id = 7;
SELECT COUNT(*)::text AS audit_in_tx FROM rental.tool_audit WHERE tool_id = 7 \gset
ROLLBACK TO SAVEPOINT sp_audit;

SELECT pg_temp.check_value('T20', 'ROLLBACK: усередині транзакції запис аудиту був (1), після відкату немає ні запису, ні нової ціни',
  '1|900.00|0',
  format($q$SELECT %L || '|' || (SELECT daily_price FROM rental.tools WHERE id = 7) || '|' ||
                   (SELECT COUNT(*) FROM rental.tool_audit WHERE tool_id = 7)$q$, :'audit_in_tx'));

-- ╔══════════════════ G. Права доступу (SET LOCAL ROLE) ═════════╗

SELECT pg_temp.run_test('T21', 'NFR01: аналітик не бачить персональних даних клієнтів (phone)',
  $q$SELECT phone FROM rental.customers$q$, '42501', 'rental_analyst');

SELECT pg_temp.run_test('T22', 'NFR02: оператор не може напряму вставляти в rentals (лише через процедуру)',
  $q$INSERT INTO rental.rentals (customer_id, employee_id, due_at) VALUES (1, 1, now() + interval '1 day')$q$,
  '42501', 'rental_operator');

SELECT pg_temp.run_test('T23', 'Менеджер не може підробити запис журналу аудиту',
  $q$INSERT INTO rental.tool_audit (tool_id, old_price, new_price) VALUES (1, 1, 2)$q$, '42501', 'rental_manager');

-- ╔══════════════════ ПРОТОКОЛ ═══════════════════════════════════╗
\pset format aligned
\pset tuples_only off

SELECT code AS "Код", description AS "Дія / опис", expected AS "Очікується", actual AS "Фактично",
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS "Результат"
FROM test_log
ORDER BY seq;

SELECT COUNT(*) AS total,
       COUNT(*) FILTER (WHERE passed)     AS passed,
       COUNT(*) FILTER (WHERE NOT passed) AS failed
FROM test_log;

-- Деталі збоїв (порожньо, якщо все пройшло)
SELECT code, expected, actual, detail FROM test_log WHERE NOT passed ORDER BY seq;

ROLLBACK;  -- усі зміни тестів скасовано; база повертається до стану після 03_seed.sql
