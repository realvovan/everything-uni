-- =====================================================================
-- Файл 08: дослідження продуктивності та індексів (розділ 5.9)
-- Запускати після 01–03. Експеримент ізольовано в окремій схемі perf,
-- тому основні дані не змінюються. Видалення: DROP SCHEMA perf CASCADE;
--
-- Методика (послідовність з розділу 5.9):
--   1) сформувати й описати набір даних та параметри запитів;
--   2) ANALYZE для актуалізації статистики;
--   3) EXPLAIN (ANALYZE, BUFFERS) початкових запитів;
--   4) внести по одній обґрунтованій зміні (індексу) на запит і повторити вимірювання;
--   5) порівняти плани, розмір індексів і вплив на вставку.
-- Кожен EXPLAIN виконайте щонайменше 3 рази за однакових умов; перший запуск
-- (холодний кеш) та повторні фіксуйте окремо. Числа часу в протокол заносьте
-- лише власні, отримані на вашому обладнанні.
-- Увага: EXPLAIN ANALYZE справді виконує запит.
-- =====================================================================
\timing on

-- ---------------------------------------------------------------------
-- 1. НАБІР ДАНИХ (спосіб генерації документується у записці)
--    100 000 оренд за період 2024-01-01 … 2026-11-10, 5 000 клієнтів,
--    1–3 позиції в оренді, ≈0,5% оренд залишаються відкритими (прострочені).
--    setseed(0.42) робить генерацію відтворюваною.
-- ---------------------------------------------------------------------
DROP SCHEMA IF EXISTS perf CASCADE;
CREATE SCHEMA perf;

CREATE TABLE perf.rentals (
    id          integer PRIMARY KEY,
    customer_id integer NOT NULL,
    employee_id integer NOT NULL,
    rented_at   timestamptz NOT NULL,
    due_at      timestamptz NOT NULL,
    status      text NOT NULL,
    closed_at   timestamptz
);
CREATE TABLE perf.rental_items (
    rental_id   integer NOT NULL,
    tool_id     integer NOT NULL,
    daily_price numeric(10,2) NOT NULL,
    PRIMARY KEY (rental_id, tool_id)
);

SELECT setseed(0.42);

-- Підзапит із volatile-функціями (random) у списку вибірки планувальник не «розгортає»,
-- тому кожне значення обчислюється рівно один раз на рядок і узгоджено використовується
-- у зовнішньому SELECT (rented_at, тривалість і статус не розходяться).
INSERT INTO perf.rentals (id, customer_id, employee_id, rented_at, due_at, status, closed_at)
SELECT x.id, x.cust, x.emp, x.rented_at,
       x.rented_at + x.dur,
       x.st,
       CASE WHEN x.st = 'closed' THEN x.rented_at + x.dur END
FROM (
    SELECT g AS id,
           1 + (random() * 4999)::int                                    AS cust,
           1 + (random() * 3)::int                                       AS emp,
           timestamptz '2024-01-01 08:00+02' + random() * interval '1045 days' AS rented_at,
           (1 + (random() * 9)::int) * interval '1 day'                  AS dur,
           CASE WHEN random() < 0.005 THEN 'open' ELSE 'closed' END      AS st
    FROM generate_series(1, 100000) AS g
) AS x;

INSERT INTO perf.rental_items (rental_id, tool_id, daily_price)
SELECT r.id, t.tool_id, 100 + (t.tool_id * 10)
FROM perf.rentals AS r
CROSS JOIN LATERAL (
    SELECT DISTINCT 1 + ((r.id::bigint * k * 7919) % 15)::int AS tool_id      -- 1…15, до 3 різних на оренду
    FROM generate_series(1, 1 + (r.id % 3)) AS k
) AS t;

ANALYZE perf.rentals;
ANALYZE perf.rental_items;

SELECT (SELECT COUNT(*) FROM perf.rentals)      AS rentals,
       (SELECT COUNT(*) FROM perf.rental_items) AS items,
       (SELECT COUNT(*) FROM perf.rentals WHERE status = 'open') AS open_rentals,
       pg_size_pretty(pg_total_relation_size('perf.rentals')) AS rentals_size,
       version() AS server_version;

-- ---------------------------------------------------------------------
-- 2. ЗАПИТИ ДЛЯ ДОСЛІДЖЕННЯ (типові операції системи)
--    QA: історія оренд клієнта за період, останні 20 (WHERE + ORDER BY + LIMIT);
--    QB: список прострочених відкритих оренд (WHERE за умовою на малу частку рядків);
--    QC: оренди конкретного інструмента за рік (JOIN; очікувано БЕЗ значного виграшу).
--    Параметри: customer_id = 1234; період від 2026-01-01; tool_id = 7.
-- ---------------------------------------------------------------------

-- ===== СТАН «ДО» (лише первинні ключі) =====
\echo '--- QA before indexing ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, rented_at, due_at, status
FROM perf.rentals
WHERE customer_id = 1234 AND rented_at >= '2026-01-01'
ORDER BY rented_at DESC
LIMIT 20;

\echo '--- QB before indexing ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, customer_id, due_at
FROM perf.rentals
WHERE status = 'open' AND due_at < now()
ORDER BY due_at;

\echo '--- QC before indexing ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.id, r.rented_at
FROM perf.rental_items AS ri
JOIN perf.rentals AS r ON r.id = ri.rental_id
WHERE ri.tool_id = 7 AND r.rented_at >= '2026-01-01';

-- Вартість змін у стані «до»: вставка 20 000 рядків у транзакції з відкатом
BEGIN;
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO perf.rentals (id, customer_id, employee_id, rented_at, due_at, status, closed_at)
SELECT 100000 + g, 1 + (g % 5000), 1, timestamptz '2026-11-01' + g * interval '1 second',
       timestamptz '2026-11-05', 'closed', timestamptz '2026-11-05'
FROM generate_series(1, 20000) AS g;
ROLLBACK;

-- ---------------------------------------------------------------------
-- 3. ЗМІНИ: індекси, обґрунтовані умовами WHERE / ORDER BY
-- ---------------------------------------------------------------------
-- QA: рівність за customer_id + діапазон і порядок за rented_at -> складений індекс;
--     DESC у визначенні дозволяє (коли це вигідно планувальнику) читати індекс у потрібному порядку.
CREATE INDEX perf_rentals_customer_time_idx
    ON perf.rentals (customer_id, rented_at DESC);

-- QB: цікавить мала частка рядків (status = 'open') -> частковий індекс по due_at;
--     він займає лічені кілобайти й може віддавати рядки в порядку due_at.
CREATE INDEX perf_rentals_open_due_idx
    ON perf.rentals (due_at) WHERE status = 'open';

-- QC: пошук позицій за tool_id (PK починається з rental_id і для цього не годиться).
CREATE INDEX perf_items_tool_idx ON perf.rental_items (tool_id, rental_id);

ANALYZE perf.rentals;
ANALYZE perf.rental_items;

-- ===== СТАН «ПІСЛЯ» (ті самі запити й параметри) =====
\echo '--- QA after indexes ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, rented_at, due_at, status
FROM perf.rentals
WHERE customer_id = 1234 AND rented_at >= '2026-01-01'
ORDER BY rented_at DESC
LIMIT 20;

\echo '--- QB after indexes ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, customer_id, due_at
FROM perf.rentals
WHERE status = 'open' AND due_at < now()
ORDER BY due_at;

\echo '--- QC after indexes ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT r.id, r.rented_at
FROM perf.rental_items AS ri
JOIN perf.rentals AS r ON r.id = ri.rental_id
WHERE ri.tool_id = 7 AND r.rented_at >= '2026-01-01';

-- Вартість змін у стані «після»: та сама вставка, але тепер оновлюються й 2 нові індекси
BEGIN;
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO perf.rentals (id, customer_id, employee_id, rented_at, due_at, status, closed_at)
SELECT 100000 + g, 1 + (g % 5000), 1, timestamptz '2026-11-01' + g * interval '1 second',
       timestamptz '2026-11-05', 'closed', timestamptz '2026-11-05'
FROM generate_series(1, 20000) AS g;
ROLLBACK;

-- ---------------------------------------------------------------------
-- 4. ВАРТІСТЬ ІНДЕКСІВ: розмір
-- ---------------------------------------------------------------------
SELECT c.relname AS index_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       pg_size_pretty(pg_relation_size('perf.rentals')) AS table_size_for_reference
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'perf' AND c.relkind = 'i'
ORDER BY c.relname;