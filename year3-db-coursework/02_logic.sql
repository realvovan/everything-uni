-- =====================================================================
-- Файл 02: програмовані об'єкти — функції, процедури, тригери,
--          представлення (розділи 5.5 та 5.6 методичних рекомендацій)
-- Запускати після 01_schema.sql.
--
-- Принципи:
--  * правило, яке виражається стандартним обмеженням, реалізовано
--    обмеженням (див. 01_schema.sql), а не тригером;
--  * тригери і процедури, що змінюють кілька таблиць, виконуються
--    з правами власника (SECURITY DEFINER) із фіксованим search_path,
--    щоб ролі з мінімальними правами могли працювати лише через них.
-- =====================================================================

-- =====================================================================
-- ЧАСТИНА 1. ФУНКЦІЇ
-- =====================================================================

-- ---------------------------------------------------------------------
-- F1. billed_days — кількість оплачуваних діб (SQL-функція, IMMUTABLE)
-- Призначення: «неповна доба = повна», мінімум 1 доба.
-- Параметри: початок та кінець оренди. Результат: integer.
-- IMMUTABLE коректно: результат залежить лише від аргументів,
-- таблиці не читаються.
-- Приклад: SELECT rental.billed_days('2026-10-01 10:00+03','2026-10-02 10:01+03'); -- 2
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.billed_days(p_from timestamptz, p_to timestamptz)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
    SELECT GREATEST(1, CEIL(EXTRACT(EPOCH FROM (p_to - p_from)) / 86400.0))::integer;
$$;

-- ---------------------------------------------------------------------
-- F2. rental_amount — вартість оренди з урахуванням знижки (SQL, STABLE)
-- Призначення: сума по позиціях (ціна-знімок × оплачувані доби),
--   помножена на (1 - знижка клієнта). Для позицій, що ще не повернуті,
--   кінець періоду = p_as_of.
-- Повертає NULL, якщо оренди не існує; 0 — якщо в оренді немає позицій.
-- STABLE: функція читає змінювані таблиці (не IMMUTABLE).
-- Приклад: SELECT rental.rental_amount(1);
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.rental_amount(
    p_rental_id integer,
    p_as_of     timestamptz DEFAULT now()
) RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT ROUND(
               COALESCE(SUM(ri.daily_price
                            * rental.billed_days(r.rented_at, COALESCE(ri.returned_at, p_as_of))), 0)
               * (1 - c.discount_percent / 100.0), 2)
    FROM rental.rentals AS r
    JOIN rental.customers AS c ON c.id = r.customer_id
    LEFT JOIN rental.rental_items AS ri ON ri.rental_id = r.id
    WHERE r.id = p_rental_id
    GROUP BY c.discount_percent;
$$;

-- ---------------------------------------------------------------------
-- F3. late_fee — штраф за прострочення (SQL, STABLE)
-- Призначення: за кожну розпочату добу після due_at нараховується
--   p_penalty_rate (за замовчуванням 50%) від ціни позиції за добу.
-- Повертає 0, якщо прострочення немає; NULL — якщо оренди не існує.
-- Приклад: SELECT rental.late_fee(3);
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.late_fee(
    p_rental_id    integer,
    p_as_of        timestamptz DEFAULT now(),
    p_penalty_rate numeric DEFAULT 0.5
) RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT ROUND(COALESCE(SUM(
               ri.daily_price * p_penalty_rate
               * GREATEST(0, CEIL(EXTRACT(EPOCH FROM
                     (COALESCE(ri.returned_at, p_as_of) - r.due_at)) / 86400.0))
           ), 0), 2)
    FROM rental.rentals AS r
    LEFT JOIN rental.rental_items AS ri ON ri.rental_id = r.id
    WHERE r.id = p_rental_id
    GROUP BY r.id;
$$;

-- =====================================================================
-- ЧАСТИНА 2. ТРИГЕРНІ ФУНКЦІЇ ТА ТРИГЕРИ
-- =====================================================================

-- ---------------------------------------------------------------------
-- T1 (BEFORE UPDATE OF status ON tools): перевірка переходу стану.
-- Дозволені переходи:
--   available   -> rented, maintenance, retired
--   rented      -> available, maintenance
--   maintenance -> available, retired
--   retired     -> (кінцевий стан)
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.tools_status_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT (
        (OLD.status = 'available'   AND NEW.status IN ('rented','maintenance','retired')) OR
        (OLD.status = 'rented'      AND NEW.status IN ('available','maintenance')) OR
        (OLD.status = 'maintenance' AND NEW.status IN ('available','retired'))
    ) THEN
        RAISE EXCEPTION 'Недопустимий перехід стану інструмента %: % -> %',
            OLD.inventory_code, OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tools_status_transition
BEFORE UPDATE OF status ON rental.tools
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION rental.tools_status_guard();

-- ---------------------------------------------------------------------
-- T2 (AFTER UPDATE OF daily_price ON tools): аудит зміни ціни.
-- SECURITY DEFINER: менеджер змінює ціну, але не має прав на tool_audit.
-- У журнал записується session_user (усередині SECURITY DEFINER
-- current_user був би власником схеми).
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.tools_price_audit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
BEGIN
    INSERT INTO rental.tool_audit (tool_id, old_price, new_price, changed_by)
    VALUES (NEW.id, OLD.daily_price, NEW.daily_price, session_user);
    RETURN NEW;
END;
$$;

CREATE TRIGGER tools_price_audit
AFTER UPDATE OF daily_price ON rental.tools
FOR EACH ROW
WHEN (OLD.daily_price IS DISTINCT FROM NEW.daily_price)
EXECUTE FUNCTION rental.tools_price_audit();

-- ---------------------------------------------------------------------
-- T3 (BEFORE INSERT ON rentals): заблокованому клієнту оренда заборонена.
-- Правило залежить від даних іншої таблиці (customers), тому тригер.
-- Читання customers блокується FOR SHARE, щоб клієнта не заблокували
-- між перевіркою та вставкою.
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.rentals_customer_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_blocked boolean;
BEGIN
    SELECT is_blocked INTO v_blocked
    FROM rental.customers
    WHERE id = NEW.customer_id
    FOR SHARE;

    IF v_blocked THEN
        RAISE EXCEPTION 'Клієнт % заблокований: оформлення оренди заборонено', NEW.customer_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER rentals_customer_check
BEFORE INSERT ON rental.rentals
FOR EACH ROW
EXECUTE FUNCTION rental.rentals_customer_guard();

-- ---------------------------------------------------------------------
-- T4 (AFTER INSERT OR UPDATE OF returned_at ON rental_items):
-- синхронізація стану інструмента з позицією оренди.
--   видача (INSERT без returned_at)  -> tools.status = 'rented'
--   повернення, стан good/worn       -> tools.status = 'available'
--   повернення, стан damaged         -> tools.status = 'maintenance'
--                                       + запис у maintenance_log
-- Якщо перехід стану недопустимий (наприклад, інструмент у ремонті),
-- T1 викликає помилку, і вся операція (INSERT позиції) скасовується.
-- Історичні вставки з уже заповненим returned_at статус не змінюють.
-- ---------------------------------------------------------------------
CREATE FUNCTION rental.rental_items_sync()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.returned_at IS NULL THEN
            UPDATE rental.tools SET status = 'rented' WHERE id = NEW.tool_id;
        END IF;
    ELSIF OLD.returned_at IS NULL AND NEW.returned_at IS NOT NULL THEN
        IF NEW.condition_in = 'damaged' THEN
            UPDATE rental.tools SET status = 'maintenance' WHERE id = NEW.tool_id;
            INSERT INTO rental.maintenance_log (tool_id, started_at, description)
            VALUES (NEW.tool_id, NEW.returned_at,
                    'Автоматично: пошкодження виявлено при поверненні з оренди ' || NEW.rental_id);
        ELSE
            UPDATE rental.tools SET status = 'available' WHERE id = NEW.tool_id;
        END IF;
    END IF;
    RETURN NULL;  -- AFTER-тригер: значення ігнорується
END;
$$;

CREATE TRIGGER rental_items_sync_status
AFTER INSERT OR UPDATE OF returned_at ON rental.rental_items
FOR EACH ROW
EXECUTE FUNCTION rental.rental_items_sync();

-- =====================================================================
-- ЧАСТИНА 3. ПРОЦЕДУРИ (виклик командою CALL)
-- Кожна процедура виконується в транзакції викликача: за помилки
-- скасовується весь оператор CALL, часткових змін не лишається.
-- Параметр OUT при CALL передається як NULL.
-- =====================================================================

-- ---------------------------------------------------------------------
-- P1. open_rental — оформлення оренди (одна бізнес-операція):
--   1) створює договір; 2) додає позиції з поточними цінами;
--   3) фіксує платіж-заставу (сума застав усіх інструментів).
-- Параметри: клієнт, співробітник, масив id інструментів, початок, строк, спосіб оплати.
-- Повертає: p_rental_id. Помилки: порожній список, дублікати,
--   невідомий інструмент, заблокований клієнт (T3), інструмент зайнятий
--   (унікальний індекс) або не в стані available (T1).
-- ---------------------------------------------------------------------
CREATE PROCEDURE rental.open_rental(
    IN  p_customer_id integer,
    IN  p_employee_id integer,
    IN  p_tool_ids    integer[],
    IN  p_rented_at   timestamptz,
    IN  p_due_at      timestamptz,
    IN  p_method      text,
    OUT p_rental_id   integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
DECLARE
    v_distinct integer;
    v_found    integer;
    v_deposit  numeric;
BEGIN
    IF p_tool_ids IS NULL OR cardinality(p_tool_ids) = 0 THEN
        RAISE EXCEPTION 'Список інструментів порожній';
    END IF;

    SELECT COUNT(DISTINCT x) INTO v_distinct FROM unnest(p_tool_ids) AS x;
    IF v_distinct <> cardinality(p_tool_ids) THEN
        RAISE EXCEPTION 'Список інструментів містить дублікати';
    END IF;

    SELECT COUNT(*), COALESCE(SUM(deposit_amount), 0)
      INTO v_found, v_deposit
    FROM rental.tools WHERE id = ANY (p_tool_ids);
    IF v_found <> v_distinct THEN
        RAISE EXCEPTION 'Серед переданих id є неіснуючі інструменти';
    END IF;

    INSERT INTO rental.rentals (customer_id, employee_id, rented_at, due_at)
    VALUES (p_customer_id, p_employee_id, p_rented_at, p_due_at)
    RETURNING id INTO p_rental_id;

    -- ORDER BY id: єдиний порядок блокування рядків запобігає взаємоблокуванням
    INSERT INTO rental.rental_items (rental_id, tool_id, daily_price)
    SELECT p_rental_id, t.id, t.daily_price
    FROM rental.tools AS t
    WHERE t.id = ANY (p_tool_ids)
    ORDER BY t.id;

    IF v_deposit > 0 THEN
        INSERT INTO rental.payments (rental_id, kind, amount, method, paid_at)
        VALUES (p_rental_id, 'deposit', v_deposit, p_method, p_rented_at);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- P2. return_tool — повернення однієї позиції. Якщо повернуто останню
--   позицію, оренда закривається, нараховуються оплата й штраф, а застава
--   повертається (за вирахуванням застав пошкоджених інструментів).
-- Повертає: p_rental_closed (TRUE, якщо оренду закрито).
-- Помилки: оренди немає / не open; позиції немає серед активних;
--   повернення раніше початку оренди.
-- ---------------------------------------------------------------------
CREATE PROCEDURE rental.return_tool(
    IN  p_rental_id     integer,
    IN  p_tool_id       integer,
    IN  p_returned_at   timestamptz,
    IN  p_condition     text,
    OUT p_rental_closed boolean
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
DECLARE
    v_rented_at timestamptz;
    v_status    text;
    v_updated   integer;
    v_amount    numeric;
    v_fee       numeric;
    v_deposit   numeric;
    v_withheld  numeric;
BEGIN
    -- FOR UPDATE: два одночасні повернення в одній оренді виконуються послідовно
    SELECT rented_at, status INTO v_rented_at, v_status
    FROM rental.rentals WHERE id = p_rental_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Оренду % не знайдено', p_rental_id;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'Оренда % має стан %, повернення неможливе', p_rental_id, v_status;
    END IF;
    IF p_returned_at < v_rented_at THEN
        RAISE EXCEPTION 'Момент повернення (%) раніше початку оренди (%)', p_returned_at, v_rented_at;
    END IF;

    UPDATE rental.rental_items
       SET returned_at = p_returned_at, condition_in = p_condition
     WHERE rental_id = p_rental_id AND tool_id = p_tool_id AND returned_at IS NULL;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
        RAISE EXCEPTION 'Інструмент % не перебуває в активній оренді %', p_tool_id, p_rental_id;
    END IF;

    p_rental_closed := NOT EXISTS (
        SELECT 1 FROM rental.rental_items
        WHERE rental_id = p_rental_id AND returned_at IS NULL);

    IF p_rental_closed THEN
        v_amount := rental.rental_amount(p_rental_id, p_returned_at);
        v_fee    := rental.late_fee(p_rental_id, p_returned_at);

        SELECT COALESCE(SUM(amount), 0) INTO v_deposit
        FROM rental.payments WHERE rental_id = p_rental_id AND kind = 'deposit';

        SELECT COALESCE(SUM(t.deposit_amount), 0) INTO v_withheld
        FROM rental.rental_items AS ri
        JOIN rental.tools AS t ON t.id = ri.tool_id
        WHERE ri.rental_id = p_rental_id AND ri.condition_in = 'damaged';

        UPDATE rental.rentals
           SET status = 'closed', closed_at = p_returned_at
         WHERE id = p_rental_id;

        INSERT INTO rental.payments (rental_id, kind, amount, paid_at)
        VALUES (p_rental_id, 'rental', v_amount, p_returned_at);
        IF v_fee > 0 THEN
            INSERT INTO rental.payments (rental_id, kind, amount, paid_at)
            VALUES (p_rental_id, 'penalty', v_fee, p_returned_at);
        END IF;
        IF v_deposit - v_withheld > 0 THEN
            INSERT INTO rental.payments (rental_id, kind, amount, paid_at)
            VALUES (p_rental_id, 'deposit_refund', v_deposit - v_withheld, p_returned_at);
        END IF;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- P3. start_maintenance — планове відправлення інструмента на обслуговування.
--   Дозволено лише для інструмента в стані available.
-- Повертає: p_log_id — id запису журналу.
-- ---------------------------------------------------------------------
CREATE PROCEDURE rental.start_maintenance(
    IN  p_tool_id     integer,
    IN  p_employee_id integer,
    IN  p_started_at  timestamptz,
    IN  p_description text,
    OUT p_log_id      bigint
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM rental.tools WHERE id = p_tool_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Інструмент % не знайдено', p_tool_id;
    END IF;
    IF v_status <> 'available' THEN
        RAISE EXCEPTION 'На обслуговування можна передати лише вільний інструмент (зараз: %)', v_status;
    END IF;

    INSERT INTO rental.maintenance_log (tool_id, employee_id, started_at, description)
    VALUES (p_tool_id, p_employee_id, p_started_at, p_description)
    RETURNING id INTO p_log_id;

    UPDATE rental.tools SET status = 'maintenance' WHERE id = p_tool_id;
END;
$$;

-- ---------------------------------------------------------------------
-- P4. finish_maintenance — завершення обслуговування: закриває запис
--   журналу (виконавець, вартість) і повертає інструмент у стан available.
-- Повертає: p_tool_id.
-- ---------------------------------------------------------------------
CREATE PROCEDURE rental.finish_maintenance(
    IN  p_log_id      bigint,
    IN  p_employee_id integer,
    IN  p_finished_at timestamptz,
    IN  p_cost        numeric,
    OUT p_tool_id     integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, rental, pg_temp
AS $$
BEGIN
    UPDATE rental.maintenance_log
       SET finished_at = p_finished_at,
           cost        = p_cost,
           employee_id = COALESCE(p_employee_id, employee_id)
     WHERE id = p_log_id AND finished_at IS NULL
    RETURNING tool_id INTO p_tool_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Відкритого запису обслуговування % не знайдено', p_log_id;
    END IF;

    UPDATE rental.tools SET status = 'available' WHERE id = p_tool_id;
END;
$$;

-- =====================================================================
-- ЧАСТИНА 4. ПРЕДСТАВЛЕННЯ
-- =====================================================================

-- V1. Інструменти, які зараз перебувають у клієнтів (для операторів).
--     Містить ознаку прострочення — повторно використовується у звітах.
CREATE VIEW rental.v_active_rentals AS
SELECT r.id            AS rental_id,
       c.full_name     AS customer,
       c.phone         AS customer_phone,
       t.inventory_code,
       t.name          AS tool_name,
       r.rented_at,
       r.due_at,
       (r.due_at < now())                                   AS is_overdue,
       GREATEST(0, CEIL(EXTRACT(EPOCH FROM (now() - r.due_at)) / 86400.0))::integer AS days_overdue
FROM rental.rental_items AS ri
JOIN rental.rentals   AS r ON r.id = ri.rental_id
JOIN rental.customers AS c ON c.id = r.customer_id
JOIN rental.tools     AS t ON t.id = ri.tool_id
WHERE ri.returned_at IS NULL;

-- V2. Остання оренда кожного інструмента (DISTINCT ON; порядок однозначний:
--     rented_at DESC, потім rental_id DESC).
CREATE VIEW rental.v_tool_last_rental AS
SELECT DISTINCT ON (ri.tool_id)
       ri.tool_id,
       r.id AS rental_id,
       r.customer_id,
       r.rented_at,
       ri.returned_at
FROM rental.rental_items AS ri
JOIN rental.rentals AS r ON r.id = ri.rental_id
ORDER BY ri.tool_id, r.rented_at DESC, r.id DESC;

-- V3. Дохід за місяцями (для аналітика): агрегована вибірка без
--     персональних даних. Застава і її повернення доходом не вважаються.
--     Місяць визначається за київським часом незалежно від налаштувань сеансу.
CREATE VIEW rental.v_monthly_revenue AS
SELECT date_trunc('month', p.paid_at AT TIME ZONE 'Europe/Kyiv')::date AS month,
       COALESCE(SUM(p.amount) FILTER (WHERE p.kind = 'rental'),  0) AS rental_income,
       COALESCE(SUM(p.amount) FILTER (WHERE p.kind = 'penalty'), 0) AS penalty_income,
       SUM(p.amount) AS total_income,
       COUNT(DISTINCT p.rental_id) AS rentals_paid
FROM rental.payments AS p
WHERE p.kind IN ('rental', 'penalty')
GROUP BY 1;
