-- =====================================================================
-- КУРСОВА РОБОТА: «Проєктування та реалізація бази даних інформаційної
-- системи оренди інструментів та обладнання»
-- Файл 01: структура БД (схема, таблиці, ключі, обмеження, індекси,
--          словник даних)
-- СУБД: PostgreSQL 15+ (використано UNIQUE NULLS NOT DISTINCT; перевірено на 16)
-- Запуск: у порожній навчальній базі, де схеми rental ще не існує.
-- =====================================================================

CREATE SCHEMA rental;

-- ---------------------------------------------------------------------
-- 1. suppliers — довідник постачальників обладнання
-- ---------------------------------------------------------------------
CREATE TABLE rental.suppliers (
    id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name   text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    phone  text,
    email  text
);

-- ---------------------------------------------------------------------
-- 2. categories — ієрархічний довідник категорій (self-reference).
--    Ієрархія потрібна для рекурсивного CTE (запит Q13).
-- ---------------------------------------------------------------------
CREATE TABLE rental.categories (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL CHECK (btrim(name) <> ''),
    parent_id  integer REFERENCES rental.categories(id) ON DELETE RESTRICT,
    -- назва унікальна в межах одного батька; NULLS NOT DISTINCT робить
    -- унікальними й назви кореневих категорій (parent_id IS NULL)
    CONSTRAINT categories_name_parent_uq UNIQUE NULLS NOT DISTINCT (parent_id, name),
    CONSTRAINT categories_not_self_parent CHECK (parent_id IS DISTINCT FROM id)
);

-- ---------------------------------------------------------------------
-- 3. tools — інвентар (одиниця обладнання, яку можна орендувати)
-- ---------------------------------------------------------------------
CREATE TABLE rental.tools (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    inventory_code  text NOT NULL UNIQUE CHECK (btrim(inventory_code) <> ''),
    name            text NOT NULL CHECK (btrim(name) <> ''),
    category_id     integer NOT NULL REFERENCES rental.categories(id) ON DELETE RESTRICT,
    supplier_id     integer REFERENCES rental.suppliers(id) ON DELETE SET NULL,
    brand           text,
    model           text,
    daily_price     numeric(10,2) NOT NULL,
    deposit_amount  numeric(10,2) NOT NULL DEFAULT 0,
    purchase_date   date NOT NULL,
    status          text NOT NULL DEFAULT 'available',
    CONSTRAINT tools_daily_price_pos   CHECK (daily_price > 0),
    CONSTRAINT tools_deposit_nonneg    CHECK (deposit_amount >= 0),
    CONSTRAINT tools_purchase_date_ok  CHECK (purchase_date >= DATE '2000-01-01'),
    CONSTRAINT tools_status_domain     CHECK (status IN ('available','rented','maintenance','retired'))
);

-- ---------------------------------------------------------------------
-- 4. customers — клієнти
-- ---------------------------------------------------------------------
CREATE TABLE rental.customers (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name        text NOT NULL CHECK (btrim(full_name) <> ''),
    phone            text NOT NULL UNIQUE,
    email            text UNIQUE,
    discount_percent numeric(4,1) NOT NULL DEFAULT 0,
    is_blocked       boolean NOT NULL DEFAULT false,
    registered_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customers_phone_fmt CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    CONSTRAINT customers_discount_range CHECK (discount_percent BETWEEN 0 AND 30)
);

-- ---------------------------------------------------------------------
-- 5. employees — співробітники пункту прокату
-- ---------------------------------------------------------------------
CREATE TABLE rental.employees (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  text NOT NULL CHECK (btrim(full_name) <> ''),
    position   text NOT NULL,
    email      text UNIQUE,
    hired_on   date NOT NULL,
    active     boolean NOT NULL DEFAULT true,
    CONSTRAINT employees_position_domain CHECK (position IN ('operator','manager','technician'))
);

-- ---------------------------------------------------------------------
-- 6. rentals — «шапка» договору оренди
-- ---------------------------------------------------------------------
CREATE TABLE rental.rentals (
    id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  integer NOT NULL REFERENCES rental.customers(id) ON DELETE RESTRICT,
    employee_id  integer NOT NULL REFERENCES rental.employees(id) ON DELETE RESTRICT,
    rented_at    timestamptz NOT NULL DEFAULT now(),
    due_at       timestamptz NOT NULL,
    status       text NOT NULL DEFAULT 'open',
    closed_at    timestamptz,
    CONSTRAINT rentals_status_domain    CHECK (status IN ('open','closed','cancelled')),
    CONSTRAINT rentals_due_after_start  CHECK (due_at > rented_at),
    CONSTRAINT rentals_max_duration     CHECK (due_at - rented_at <= interval '60 days'),
    CONSTRAINT rentals_closed_consistent CHECK ((status = 'closed') = (closed_at IS NOT NULL)),
    CONSTRAINT rentals_closed_after_start CHECK (closed_at IS NULL OR closed_at >= rented_at)
);

-- ---------------------------------------------------------------------
-- 7. rental_items — проміжна таблиця зв'язку N:M (оренда ↔ інструмент).
--    Власні атрибути зв'язку: ціна на момент оренди, дата та стан
--    повернення. Ціна зберігається «знімком» — свідома денормалізація:
--    зміна tools.daily_price не повинна змінювати вартість старих оренд.
-- ---------------------------------------------------------------------
CREATE TABLE rental.rental_items (
    rental_id    integer NOT NULL REFERENCES rental.rentals(id) ON DELETE RESTRICT,
    tool_id      integer NOT NULL REFERENCES rental.tools(id)   ON DELETE RESTRICT,
    daily_price  numeric(10,2) NOT NULL,
    returned_at  timestamptz,
    condition_in text,
    PRIMARY KEY (rental_id, tool_id),
    CONSTRAINT rental_items_price_pos   CHECK (daily_price > 0),
    CONSTRAINT rental_items_cond_domain CHECK (condition_in IN ('good','worn','damaged')),
    -- повернення і стан при поверненні фіксуються разом
    CONSTRAINT rental_items_return_consistent CHECK ((returned_at IS NULL) = (condition_in IS NULL))
);

-- Один інструмент може одночасно перебувати лише в одній незакритій оренді.
-- Це надійніше за тригер: індекс працює коректно за конкурентного доступу.
CREATE UNIQUE INDEX rental_items_one_active_uq
    ON rental.rental_items (tool_id) WHERE returned_at IS NULL;

-- Історія оренд конкретного інструмента (PK починається з rental_id і для цього непридатний)
CREATE INDEX rental_items_tool_idx ON rental.rental_items (tool_id);

-- ---------------------------------------------------------------------
-- 8. payments — рух коштів за орендою
--    kind: deposit (застава — надходження), rental (оплата оренди),
--          penalty (штраф за прострочення), deposit_refund (повернення застави — видаток)
-- ---------------------------------------------------------------------
CREATE TABLE rental.payments (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rental_id integer NOT NULL REFERENCES rental.rentals(id) ON DELETE RESTRICT,
    kind      text NOT NULL,
    amount    numeric(12,2) NOT NULL,
    method    text NOT NULL DEFAULT 'card',
    paid_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payments_kind_domain   CHECK (kind IN ('deposit','rental','penalty','deposit_refund')),
    CONSTRAINT payments_method_domain CHECK (method IN ('cash','card','transfer')),
    CONSTRAINT payments_amount_pos    CHECK (amount > 0)
);
CREATE INDEX payments_rental_idx ON rental.payments (rental_id);

-- ---------------------------------------------------------------------
-- 9. maintenance_log — історія технічного обслуговування
-- ---------------------------------------------------------------------
CREATE TABLE rental.maintenance_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tool_id      integer NOT NULL REFERENCES rental.tools(id) ON DELETE RESTRICT,
    employee_id  integer REFERENCES rental.employees(id) ON DELETE RESTRICT, -- NULL = виконавця ще не призначено
    started_at   timestamptz NOT NULL,
    finished_at  timestamptz,
    description  text NOT NULL CHECK (btrim(description) <> ''),
    cost         numeric(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT maintenance_cost_nonneg  CHECK (cost >= 0),
    CONSTRAINT maintenance_period_ok    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
-- Не більше одного незавершеного обслуговування на інструмент
CREATE UNIQUE INDEX maintenance_one_open_uq
    ON rental.maintenance_log (tool_id) WHERE finished_at IS NULL;

-- ---------------------------------------------------------------------
-- 10. tool_audit — журнал аудиту зміни ціни (заповнюється тригером)
-- ---------------------------------------------------------------------
CREATE TABLE rental.tool_audit (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tool_id    integer NOT NULL REFERENCES rental.tools(id) ON DELETE RESTRICT,
    old_price  numeric(10,2) NOT NULL,
    new_price  numeric(10,2) NOT NULL,
    changed_by text NOT NULL DEFAULT session_user,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Індекси для зовнішніх ключів, що використовуються у з'єднаннях.
-- Індекси для дослідження продуктивності навмисно винесено у файл 08.
CREATE INDEX tools_category_idx    ON rental.tools (category_id);
CREATE INDEX rentals_customer_idx  ON rental.rentals (customer_id);
CREATE INDEX maintenance_tool_idx  ON rental.maintenance_log (tool_id);

-- ---------------------------------------------------------------------
-- СЛОВНИК ДАНИХ: коментарі до таблиць і стовпців (COMMENT ON ...)
-- Словник можна вивести запитом наприкінці файлу.
-- ---------------------------------------------------------------------
COMMENT ON TABLE rental.suppliers        IS 'Довідник постачальників обладнання';
COMMENT ON TABLE rental.categories       IS 'Ієрархічний довідник категорій інструментів';
COMMENT ON TABLE rental.tools            IS 'Інвентар: одиниці обладнання, доступні для оренди';
COMMENT ON TABLE rental.customers        IS 'Клієнти пункту прокату';
COMMENT ON TABLE rental.employees        IS 'Співробітники пункту прокату';
COMMENT ON TABLE rental.rentals          IS 'Договори оренди (шапка)';
COMMENT ON TABLE rental.rental_items     IS 'Позиції договору: зв''язок N:M між орендою та інструментом';
COMMENT ON TABLE rental.payments         IS 'Платежі за орендою: застава, оплата, штраф, повернення застави';
COMMENT ON TABLE rental.maintenance_log  IS 'Історія технічного обслуговування та ремонту';
COMMENT ON TABLE rental.tool_audit       IS 'Журнал аудиту змін ціни інструмента (пишеться тригером)';

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
          ('categories','parent_id','Батьківська категорія; NULL для кореневих'),
          ('tools','inventory_code','Унікальний інвентарний код (наклейка на інструменті)'),
          ('tools','category_id','Категорія інструмента'),
          ('tools','supplier_id','Постачальник; NULL допустимо (подарунок, власна розробка)'),
          ('tools','daily_price','Поточна ціна оренди за добу, грн; > 0'),
          ('tools','deposit_amount','Застава, грн; >= 0'),
          ('tools','status','Стан: available | rented | maintenance | retired; переходи контролює тригер'),
          ('customers','phone','Телефон у міжнародному форматі; унікальний'),
          ('customers','discount_percent','Персональна знижка, %; 0..30'),
          ('customers','is_blocked','TRUE — клієнту заборонено нові оренди'),
          ('employees','position','Посада: operator | manager | technician'),
          ('rentals','rented_at','Момент видачі інструментів'),
          ('rentals','due_at','Узгоджений момент повернення; строго після rented_at, не довше 60 діб'),
          ('rentals','status','open | closed | cancelled'),
          ('rentals','closed_at','Момент повернення останньої позиції; NOT NULL лише для closed'),
          ('rental_items','daily_price','Ціна за добу на момент видачі (знімок tools.daily_price)'),
          ('rental_items','returned_at','Момент повернення позиції; NULL — інструмент ще у клієнта'),
          ('rental_items','condition_in','Стан при поверненні: good | worn | damaged'),
          ('payments','kind','deposit | rental | penalty | deposit_refund'),
          ('payments','amount','Сума, грн; завжди > 0, напрям визначає kind'),
          ('payments','method','cash | card | transfer'),
          ('maintenance_log','employee_id','Виконавець; NULL — ще не призначено'),
          ('maintenance_log','finished_at','NULL — обслуговування триває'),
          ('maintenance_log','cost','Вартість робіт і запчастин, грн'),
          ('tool_audit','changed_by','Користувач сеансу (session_user), що змінив ціну')
        ) AS t(tbl, col, descr)
    LOOP
        EXECUTE format('COMMENT ON COLUMN rental.%I.%I IS %L', r.tbl, r.col, r.descr);
    END LOOP;
END;
$$;

-- Запит для формування словника даних (таблиця 5.3 методичних рекомендацій)
-- SELECT c.table_name  AS "Таблиця",
--        c.column_name AS "Стовпець",
--        c.data_type   AS "Тип",
--        c.is_nullable AS "NULL",
--        c.column_default AS "DEFAULT",
--        col_description(format('rental.%I', c.table_name)::regclass, c.ordinal_position) AS "Призначення"
-- FROM information_schema.columns AS c
-- WHERE c.table_schema = 'rental'
-- ORDER BY c.table_name, c.ordinal_position;
