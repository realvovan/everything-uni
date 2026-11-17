-- =====================================================================
-- Файл 04: SQL-запити та операції зміни даних (розділ 5.5)
-- Запускати після 01–03 (та 05, якщо потрібні ролі).
-- Кожен запит: питання користувача -> SQL -> очікуваний результат -> пояснення.
-- «Поточна дата» сценаріїв — 2026-11-11; запити з now() залежать від дати запуску
-- (склад рядків не змінюється, змінюється лише кількість днів прострочення).
-- =====================================================================

-- ╔═══════════════════════════════════════════════════════════════════╗
-- ║ ЧАСТИНА А. SELECT-запити (19)                                      ║
-- ╚═══════════════════════════════════════════════════════════════════╝

-- ---------------------------------------------------------------------
-- Q01 [INNER JOIN, 4 таблиці]
-- Питання: що і в кого зараз перебуває на руках та коли має бути повернуто?
-- ---------------------------------------------------------------------
SELECT r.id AS rental_id,
       c.full_name AS customer,
       t.inventory_code,
       t.name AS tool,
       r.due_at
FROM rental.rental_items AS ri
JOIN rental.rentals   AS r ON r.id = ri.rental_id
JOIN rental.customers AS c ON c.id = r.customer_id
JOIN rental.tools     AS t ON t.id = ri.tool_id
WHERE ri.returned_at IS NULL
ORDER BY r.due_at, t.inventory_code;
-- Очікуваний результат (5 рядків):
--   10 | Ткаченко Василь  | T-011 | Husqvarna LC140      | 04.11.2026
--   11 | ТОВ «БудСервіс»  | T-010 | Forte 125 л          | 12.11.2026
--   11 | ТОВ «БудСервіс»  | T-014 | Karcher K5           | 12.11.2026
--    9 | Іваненко Олег    | T-003 | DeWalt DCD777        | 14.11.2026
--    9 | Іваненко Олег    | T-015 | Bosch PST 700        | 14.11.2026
-- Пояснення: INNER JOIN залишає лише позиції з наявними зв'язками; умова
-- returned_at IS NULL означає «інструмент ще у клієнта». Час у виводі залежить від TimeZone сеансу.

-- ---------------------------------------------------------------------
-- Q02 [представлення + умова]
-- Питання: кому телефонувати щодо прострочених повернень?
-- ---------------------------------------------------------------------
SELECT rental_id, customer, customer_phone, inventory_code, due_at, days_overdue
FROM rental.v_active_rentals
WHERE is_overdue
ORDER BY days_overdue DESC, rental_id;
-- Очікуваний результат: 1 рядок — оренда 10, Ткаченко Василь, T-011, строк 04.11.2026.
-- days_overdue залежить від дати запуску (станом на 11.11.2026 — 8 розпочатих діб).
-- Пояснення: прострочення обчислено один раз у представленні v_active_rentals і повторно використано.

-- ---------------------------------------------------------------------
-- Q03 [LEFT JOIN: об'єкти без подій]
-- Питання: які інструменти жодного разу не видавалися в оренду?
-- ---------------------------------------------------------------------
SELECT t.inventory_code, t.name, t.status
FROM rental.tools AS t
LEFT JOIN rental.rental_items AS ri ON ri.tool_id = t.id
WHERE ri.tool_id IS NULL
ORDER BY t.inventory_code;
-- Очікуваний результат: T-004 (maintenance) та T-016 (retired).
-- Пояснення: LEFT JOIN зберігає інструменти без позицій; умова ri.tool_id IS NULL
-- відбирає саме їх (перевірка по ключовому стовпцю правої таблиці).

-- ---------------------------------------------------------------------
-- Q04 [GROUP BY, COUNT/AVG/SUM, LEFT JOIN]
-- Питання: скільки інструментів у кожній категорії, яка середня ціна й сума застав?
-- ---------------------------------------------------------------------
SELECT c.name AS category,
       COUNT(t.id)                          AS tools_count,
       ROUND(AVG(t.daily_price), 2)         AS avg_daily_price,
       COALESCE(SUM(t.deposit_amount), 0)   AS total_deposit
FROM rental.categories AS c
LEFT JOIN rental.tools AS t ON t.category_id = c.id
GROUP BY c.id, c.name
ORDER BY tools_count DESC, c.name;
-- Очікуваний результат (9 рядків), зокрема:
--   Газонокосарки та тримери | 3 | 360.00 | 7000.00
--   Дрилі та перфоратори     | 3 | 250.00 | 4300.00
--   Генератори               | 2 | 800.00 | 10500.00
--   Будівельне обладнання    | 0 | NULL   | 0       <- кореневу категорію без власних інструментів збережено
-- Пояснення: COUNT(t.id), а не COUNT(*), дає 0 для категорій без інструментів;
-- AVG повертає NULL, SUM загорнуто в COALESCE.

-- ---------------------------------------------------------------------
-- Q05 [GROUP BY + HAVING]
-- Питання: які клієнти мають не менше двох оплачених оренд і скільки сплатили (оренда + штрафи)?
-- ---------------------------------------------------------------------
SELECT c.full_name,
       COUNT(DISTINCT r.id) AS rentals_count,
       SUM(p.amount)        AS paid_total
FROM rental.customers AS c
JOIN rental.rentals   AS r ON r.customer_id = c.id
JOIN rental.payments  AS p ON p.rental_id = r.id AND p.kind IN ('rental', 'penalty')
GROUP BY c.id, c.full_name
HAVING COUNT(DISTINCT r.id) >= 2
ORDER BY paid_total DESC;
-- Очікуваний результат (3 рядки):
--   ТОВ «БудСервіс»          | 2 | 12231.00
--   Коваленко Марія Іванівна | 2 |  6296.00
--   Іваненко Олег Петрович   | 2 |  3000.00
-- Пояснення: HAVING фільтрує вже згруповані дані; COUNT(DISTINCT r.id) потрібен, бо
-- JOIN із payments множить рядки оренди (оплата + штраф).

-- ---------------------------------------------------------------------
-- Q06 [FILTER: умовні підсумки]
-- Питання: як часто кожен інструмент орендували і в якому стані його повертали?
-- ---------------------------------------------------------------------
SELECT t.inventory_code,
       COUNT(*)                                          AS times_rented,
       COUNT(*) FILTER (WHERE ri.condition_in = 'good')    AS returned_good,
       COUNT(*) FILTER (WHERE ri.condition_in = 'worn')    AS returned_worn,
       COUNT(*) FILTER (WHERE ri.condition_in = 'damaged') AS returned_damaged,
       COUNT(*) FILTER (WHERE ri.returned_at IS NULL)      AS still_out
FROM rental.tools AS t
JOIN rental.rental_items AS ri ON ri.tool_id = t.id
GROUP BY t.id, t.inventory_code
ORDER BY times_rented DESC, t.inventory_code;
-- Очікуваний результат (14 рядків), зокрема:
--   T-001 | 2 | good 2 | worn 0 | damaged 0 | still_out 0
--   T-011 | 2 | good 0 | worn 0 | damaged 1 | still_out 1
--   T-010 | 2 | good 0 | worn 1 | damaged 0 | still_out 1
-- Пояснення: FILTER задає кілька умовних підсумків за один прохід по даних
-- (замість кількох підзапитів або CASE всередині SUM).

-- ---------------------------------------------------------------------
-- Q07 [EXISTS]
-- Питання: які клієнти хоча б раз повернули інструмент пошкодженим?
-- ---------------------------------------------------------------------
SELECT c.id, c.full_name
FROM rental.customers AS c
WHERE EXISTS (
    SELECT 1
    FROM rental.rentals AS r
    JOIN rental.rental_items AS ri ON ri.rental_id = r.id
    WHERE r.customer_id = c.id AND ri.condition_in = 'damaged');
-- Очікуваний результат: 3 | ТОВ «БудСервіс» (повернуло T-011 пошкодженим в оренді 3).
-- Пояснення: EXISTS зупиняється на першому знайденому рядку і не дублює клієнта,
-- як це зробив би JOIN за кількох пошкоджень.

-- ---------------------------------------------------------------------
-- Q08 [NOT EXISTS]
-- Питання: які зареєстровані клієнти ще не оформлювали жодної (непоскасованої) оренди?
-- ---------------------------------------------------------------------
SELECT c.id, c.full_name, c.is_blocked
FROM rental.customers AS c
WHERE NOT EXISTS (
    SELECT 1 FROM rental.rentals AS r
    WHERE r.customer_id = c.id AND r.status <> 'cancelled')
ORDER BY c.id;
-- Очікуваний результат: 7 Савчук Наталія (f), 8 Петренко Дмитро (t, заблокований).
-- Пояснення: NOT EXISTS — «антиджойн». Скасована оренда 12 не рахується, тому
-- клієнти, що мають лише скасовану оренду, також потрапили б у вибірку.

-- ---------------------------------------------------------------------
-- Q09 [підзапит з агрегатом]
-- Питання: які діючі інструменти дорожчі за середню ціну своєї категорії?
-- ---------------------------------------------------------------------
SELECT t.inventory_code, t.name, t.daily_price,
       (SELECT ROUND(AVG(t2.daily_price), 2)
        FROM rental.tools AS t2
        WHERE t2.category_id = t.category_id AND t2.status <> 'retired') AS category_avg
FROM rental.tools AS t
WHERE t.status <> 'retired'
  AND t.daily_price > (SELECT AVG(t2.daily_price)
                       FROM rental.tools AS t2
                       WHERE t2.category_id = t.category_id AND t2.status <> 'retired')
ORDER BY t.inventory_code;
-- Очікуваний результат (7 рядків): T-001 350 (середня 325), T-003 200 (190), T-006 170 (160),
--   T-007 900 (800), T-009 400 (360), T-011 450 (360), T-012 380 (360).
-- Пояснення: корельований підзапит порівнює ціну з агрегатом власної категорії;
-- списані інструменти виключено з обох частин. Категорії з однією позицією не потрапляють.

-- ---------------------------------------------------------------------
-- Q10 [DISTINCT ON: останній запис]
-- Питання: коли і з яким результатом була остання оренда кожного клієнта?
-- Порядок однозначний: rented_at DESC, id DESC.
-- ---------------------------------------------------------------------
SELECT DISTINCT ON (r.customer_id)
       r.customer_id, c.full_name, r.id AS last_rental_id, r.rented_at, r.status
FROM rental.rentals AS r
JOIN rental.customers AS c ON c.id = r.customer_id
ORDER BY r.customer_id, r.rented_at DESC, r.id DESC;
-- Очікуваний результат (6 рядків): клієнт 1 -> оренда 9 (open); 2 -> 7 (closed); 3 -> 11 (open);
--   4 -> 5 (closed); 5 -> 12 (cancelled); 6 -> 10 (open). Клієнтів 7 і 8 немає — оренд не мали.
-- Пояснення: DISTINCT ON залишає перший рядок кожної групи за порядком ORDER BY.

-- ---------------------------------------------------------------------
-- Q11 [віконна функція RANK + агрегат]
-- Питання: рейтинг популярності інструментів усередині кожної категорії.
-- PARTITION BY category_id — рейтинг у межах категорії; ORDER BY кількості оренд
-- за спаданням; за рівної кількості місце однакове (RANK). Рамка вікна не потрібна.
-- ---------------------------------------------------------------------
SELECT cat.name AS category,
       t.inventory_code,
       COUNT(ri.rental_id) AS times_rented,
       RANK() OVER (PARTITION BY t.category_id ORDER BY COUNT(ri.rental_id) DESC) AS rank_in_category
FROM rental.tools AS t
JOIN rental.categories AS cat ON cat.id = t.category_id
LEFT JOIN rental.rental_items AS ri ON ri.tool_id = t.id
WHERE t.status <> 'retired'
GROUP BY cat.name, t.category_id, t.id, t.inventory_code
ORDER BY cat.name, rank_in_category, t.inventory_code;
-- Очікуваний результат (15 рядків), зокрема:
--   Бетономішалки: T-009 і T-010 — по 2 оренди, обидва на місці 1 (RANK дає однакове місце);
--   Газонокосарки: T-011 — 1, T-012 і T-013 — спільне місце 2;
--   Акумуляторні шуруповерти: T-003 — 1, T-004 (0 оренд) — 2.
-- Пояснення: віконна функція застосовується ПІСЛЯ GROUP BY, тому всередині OVER можна
-- використовувати агрегат COUNT. Після місць 1,1 наступне місце було б 3 (прогалини RANK).

-- ---------------------------------------------------------------------
-- Q12 [LAG]
-- Питання: як часто повертаються клієнти — скільки діб між сусідніми орендами?
-- PARTITION BY customer_id, ORDER BY rented_at; для першої оренди LAG = NULL.
-- ---------------------------------------------------------------------
SELECT customer_id, rental_id, rented_at, days_since_prev
FROM (
    SELECT r.customer_id,
           r.id AS rental_id,
           r.rented_at,
           ROUND(EXTRACT(EPOCH FROM
                 r.rented_at - LAG(r.rented_at) OVER (PARTITION BY r.customer_id ORDER BY r.rented_at))
                 / 86400.0, 1) AS days_since_prev
    FROM rental.rentals AS r
    WHERE r.status <> 'cancelled'
) AS x
WHERE days_since_prev IS NOT NULL
ORDER BY customer_id, rented_at;
-- Очікуваний результат (5 рядків): клієнт 1: оренда 4 — 23.0 доби, оренда 9 — 35.0;
--   клієнт 2: оренда 7 — 30.0; клієнт 3: оренда 8 — 24.0, оренда 11 — 26.0.
-- Пояснення: LAG бере попередній rented_at у межах клієнта; перші оренди (NULL) відсіяно
-- зовнішнім запитом, бо віконні функції не можна використовувати у WHERE.

-- ---------------------------------------------------------------------
-- Q13 [рекурсивний CTE]
-- Питання: показати дерево категорій з рівнем вкладеності та кількістю інструментів у кожній.
-- ---------------------------------------------------------------------
WITH RECURSIVE tree AS (
    SELECT id, name, 1 AS depth, name::text AS path
    FROM rental.categories
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.name, tr.depth + 1, tr.path || ' → ' || c.name
    FROM rental.categories AS c
    JOIN tree AS tr ON c.parent_id = tr.id
)
SELECT tree.depth,
       repeat('    ', tree.depth - 1) || tree.name AS category_tree,
       COUNT(t.id) AS tools_count
FROM tree
LEFT JOIN rental.tools AS t ON t.category_id = tree.id
GROUP BY tree.id, tree.depth, tree.name, tree.path
ORDER BY tree.path;
-- Очікуваний результат (9 рядків):
--   Будівельне обладнання (0)
--       Бетономішалки (2)
--       Генератори (2)
--   Електроінструмент (1)
--       Дрилі та перфоратори (3)
--           Акумуляторні шуруповерти (2)
--       Шліфувальні машини (2)
--   Садова техніка (1)
--       Газонокосарки та тримери (3)
-- Пояснення: нерекурсивна частина бере корені (parent_id IS NULL), рекурсивна — дочірні
-- записи, збільшуючи depth; path забезпечує коректне впорядкування «дерева».

-- ---------------------------------------------------------------------
-- Q14 [CTE + накопичувальна сума + ковзне середнє]
-- Питання: тижнева виручка (оренда + штрафи), наростаючий підсумок і ковзне середнє за 2 тижні.
-- Рамка: ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW — накопичення з початку;
--        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW — поточний та попередній тиждень.
-- ---------------------------------------------------------------------
WITH weekly AS (
    SELECT date_trunc('week', p.paid_at AT TIME ZONE 'Europe/Kyiv')::date AS week_start,
           SUM(p.amount) AS revenue
    FROM rental.payments AS p
    WHERE p.kind IN ('rental', 'penalty')
    GROUP BY 1
)
SELECT week_start,
       revenue,
       SUM(revenue) OVER (ORDER BY week_start
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative,
       ROUND(AVG(revenue) OVER (ORDER BY week_start
                                ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), 2) AS moving_avg_2w
FROM weekly
ORDER BY week_start;
-- Очікуваний результат (6 тижнів; тижні без платежів відсутні):
--   2026-09-07 | 1650.00 |  1650.00 | 1650.00
--   2026-09-14 | 4320.00 |  5970.00 | 2985.00
--   2026-09-28 | 8631.00 | 14601.00 | 6475.50
--   2026-10-05 | 3800.00 | 18401.00 | 6215.50
--   2026-10-12 | 1197.00 | 19598.00 | 2498.50
--   2026-10-19 | 5576.00 | 25174.00 | 3386.50
-- Пояснення: ковзне середнє рахується по двох послідовних РЯДКАХ (тижнях із платежами),
-- а не календарних тижнях; для календарних потрібен generate_series. Застава не є виручкою.

-- ---------------------------------------------------------------------
-- Q15 [багатокроковий CTE + функції + ранжування]
-- Питання: хто з операторів оформив оренд на більшу суму (тільки закриті оренди)?
-- ---------------------------------------------------------------------
WITH closed AS (
    SELECT r.id, r.employee_id,
           rental.rental_amount(r.id) + rental.late_fee(r.id) AS total_with_fee
    FROM rental.rentals AS r
    WHERE r.status = 'closed'
)
SELECT e.full_name,
       COUNT(*)                        AS rentals_closed,
       SUM(cl.total_with_fee)          AS revenue,
       RANK() OVER (ORDER BY SUM(cl.total_with_fee) DESC) AS place
FROM closed AS cl
JOIN rental.employees AS e ON e.id = cl.employee_id
GROUP BY e.id, e.full_name
ORDER BY place;
-- Очікуваний результат: Лисенко Тарас — 5 оренд, 18307.00, місце 1; Гриценко Оксана — 3, 6867.00, місце 2.
-- Пояснення: CTE closed обчислює суму оренди та штраф функціями F2 і F3;
-- RANK() OVER (ORDER BY SUM(...)) ранжує вже згруповані дані.

-- ---------------------------------------------------------------------
-- Q16 [завантаженість за період: перетин інтервалів]
-- Питання: який відсоток жовтня 2026 кожен інструмент перебував в оренді?
-- Інтервал оренди обрізається межами періоду: GREATEST(початок) / LEAST(кінець).
-- ---------------------------------------------------------------------
WITH period AS (
    SELECT '2026-10-01 00:00+03'::timestamptz AS p_start,
           '2026-11-01 00:00+02'::timestamptz AS p_end
)
SELECT t.inventory_code,
       ROUND(SUM(GREATEST(0, EXTRACT(EPOCH FROM
               LEAST(COALESCE(ri.returned_at, p.p_end), p.p_end)
             - GREATEST(r.rented_at, p.p_start)))) / 3600.0, 1)                AS hours_rented,
       ROUND(100.0 * SUM(GREATEST(0, EXTRACT(EPOCH FROM
               LEAST(COALESCE(ri.returned_at, p.p_end), p.p_end)
             - GREATEST(r.rented_at, p.p_start))))
             / EXTRACT(EPOCH FROM (p.p_end - p.p_start)), 1)                   AS utilization_pct
FROM period AS p
CROSS JOIN rental.rental_items AS ri
JOIN rental.rentals AS r ON r.id = ri.rental_id
JOIN rental.tools   AS t ON t.id = ri.tool_id
WHERE r.rented_at < p.p_end AND COALESCE(ri.returned_at, p.p_end) > p.p_start
GROUP BY t.id, t.inventory_code, p.p_start, p.p_end
ORDER BY utilization_pct DESC, t.inventory_code;
-- Очікуваний результат (9 рядків), зокрема:
--   T-009: 238.5 год, 32.0%  (оренда 8 — майже 10 діб)
--   T-001 та T-006: 95.0 год, 12.8%
--   T-011:  87.0 год, 11.7%  (оренда 10 ще триває: інтервал обрізано кінцем жовтня)
-- Пояснення: перетин [rented_at, returned_at) з періодом = LEAST(кінців) - GREATEST(початків);
-- відкрита позиція вважається такою, що триває до кінця періоду. Період — 745 год через перехід на зимовий час.

-- ---------------------------------------------------------------------
-- Q17 [JOIN + агрегати по ремонту]
-- Питання: у яких категорій найдорожче обслуговування та як довго тривають ремонти?
-- ---------------------------------------------------------------------
SELECT cat.name AS category,
       COUNT(m.id)                         AS maintenance_events,
       SUM(m.cost)                         AS total_cost,
       ROUND(AVG(EXTRACT(EPOCH FROM (m.finished_at - m.started_at)) / 3600.0)
             FILTER (WHERE m.finished_at IS NOT NULL), 1) AS avg_hours_finished
FROM rental.maintenance_log AS m
JOIN rental.tools      AS t   ON t.id = m.tool_id
JOIN rental.categories AS cat ON cat.id = t.category_id
GROUP BY cat.id, cat.name
ORDER BY total_cost DESC, cat.name;
-- Очікуваний результат (4 рядки):
--   Газонокосарки та тримери | 1 | 850.00 | 101.0 год
--   Дрилі та перфоратори     | 1 | 450.00 |  31.0
--   Генератори               | 1 | 300.00 |  27.0
--   Акумуляторні шуруповерти | 1 |   0.00 | NULL (обслуговування T-004 ще триває)
-- Пояснення: AVG ... FILTER не враховує незавершені ремонти, SUM(cost) — їх вартість (0 до завершення).

-- ---------------------------------------------------------------------
-- Q18 [використання власних функцій]
-- Питання: скільки коштує кожна оренда і який штраф нараховано/накопичено?
-- Для відкритих оренд сума обчислюється на поточний момент (now()).
-- ---------------------------------------------------------------------
SELECT r.id, r.status,
       rental.rental_amount(r.id) AS amount,
       rental.late_fee(r.id)      AS late_fee
FROM rental.rentals AS r
ORDER BY r.id;
-- Очікуваний результат: оренди 1–8 закриті (1650 / 3420+900 / 8181+450 / 1350 / 2100+350 / 1197 / 1976 / 3600);
--   відкриті 9 — 1600.00, 10 — 6750.00 + штраф 1800.00, 11 — 1755.00 (залежать від дати запуску);
--   скасована 12 — 0.00 / 0.00 (немає позицій).
-- Пояснення: функції дозволяють повторно використати бізнес-логіку розрахунку; значення збігаються
-- з платежами, які створила процедура return_tool (для оренди 9 це перевіряє тест T15).

-- ---------------------------------------------------------------------
-- Q19 [представлення v_tool_last_rental + LEFT JOIN]
-- Питання: стан кожного інструмента, остання оренда та скільки діб він простоює.
-- ---------------------------------------------------------------------
SELECT t.inventory_code, t.status,
       lr.rental_id AS last_rental_id, lr.rented_at AS last_rented_at,
       CASE WHEN t.status = 'available' AND lr.returned_at IS NOT NULL
            THEN FLOOR(EXTRACT(EPOCH FROM (now() - lr.returned_at)) / 86400)::integer
       END AS idle_days
FROM rental.tools AS t
LEFT JOIN rental.v_tool_last_rental AS lr ON lr.tool_id = t.id
ORDER BY t.inventory_code;
-- Очікуваний результат (16 рядків): для T-004 та T-016 оренд немає (NULL); для інструментів «в оренді»
--   idle_days = NULL; для вільних — кількість діб від повернення (T-001 — 23, T-007 — 54 на 11.11.2026).
-- Пояснення: представлення v_tool_last_rental (DISTINCT ON) повторно використано у LEFT JOIN.

-- ╔═══════════════════════════════════════════════════════════════════╗
-- ║ ЧАСТИНА Б. Операції зміни даних (INSERT / UPDATE / DELETE / UPSERT) ║
-- ║ Виконуються в транзакції з відкатом, щоб не змінювати тестові       ║
-- ║ дані для наступних перевірок. Для збереження замініть               ║
-- ║ ROLLBACK на COMMIT.                                                 ║
-- ╚═══════════════════════════════════════════════════════════════════╝
BEGIN;

-- M1 [INSERT ... RETURNING]: реєстрація нового клієнта.
-- RETURNING повертає згенерований id і дату реєстрації без додаткового SELECT.
INSERT INTO rental.customers (full_name, phone, email)
VALUES ('Гончар Олександра', '+380501000111', 'goncharo@example.com')
RETURNING id, full_name, discount_percent, is_blocked, registered_at IS NOT NULL AS has_reg_date;
-- Очікуваний результат: 9 | Гончар Олександра | 0.0 | f | t

-- M2 [UPDATE з підзапитом + RETURNING]: програма лояльності —
-- +5 п.п. знижки клієнтам, які сплатили від 5000 грн; верхня межа 30% (LEAST).
UPDATE rental.customers AS c
SET discount_percent = LEAST(30, c.discount_percent + 5)
WHERE c.id IN (
    SELECT r.customer_id
    FROM rental.rentals AS r
    JOIN rental.payments AS p ON p.rental_id = r.id AND p.kind IN ('rental', 'penalty')
    GROUP BY r.customer_id
    HAVING SUM(p.amount) >= 5000)
RETURNING c.id, c.full_name, c.discount_percent;
-- Очікуваний результат: 2 Коваленко Марія — 10.0; 3 ТОВ «БудСервіс» — 15.0 (UPDATE 2).

-- M3 [UPDATE стану інструмента]: списання інструмента, що перебуває в ремонті
-- (maintenance -> retired дозволено тригером T1).
UPDATE rental.tools SET status = 'retired' WHERE inventory_code = 'T-004'
RETURNING inventory_code, status;
-- Очікуваний результат: T-004 | retired (UPDATE 1). Спроба retired -> available дала б помилку T1.

-- M4 [UPSERT: INSERT ... ON CONFLICT DO UPDATE]: імпорт нового прайсу.
-- Існуючий T-001 отримує нову ціну (спрацює тригер аудиту), невідомий T-099 додається.
INSERT INTO rental.tools
    (inventory_code, name, category_id, brand, model, daily_price, deposit_amount, purchase_date)
VALUES
    ('T-001', 'Перфоратор Bosch GBH 2-26', (SELECT id FROM rental.categories WHERE name = 'Дрилі та перфоратори'),
     'Bosch', 'GBH 2-26', 380.00, 2000.00, '2024-03-15'),
    ('T-099', 'Штроборіз Makita SG1251', (SELECT id FROM rental.categories WHERE name = 'Електроінструмент'),
     'Makita', 'SG1251', 260.00, 1500.00, '2026-11-01')
ON CONFLICT (inventory_code) DO UPDATE
SET daily_price    = EXCLUDED.daily_price,
    deposit_amount = EXCLUDED.deposit_amount
RETURNING inventory_code, daily_price, (xmax = 0) AS inserted;   -- xmax = 0 — новий рядок, інакше оновлений
-- Очікуваний результат: T-001 | 380.00 | f (оновлено); T-099 | 260.00 | t (вставлено).

-- Аудит зафіксував зміну ціни T-001 (тригер T2)
SELECT t.inventory_code, a.old_price, a.new_price
FROM rental.tool_audit AS a JOIN rental.tools AS t ON t.id = a.tool_id;
-- Очікуваний результат: T-001 | 350.00 | 380.00 — рядок аудиту створено тригером T2.

-- M5 [UPSERT ... DO NOTHING]: додавання постачальника, який уже існує, — без помилки й без дубліката.
INSERT INTO rental.suppliers (name, phone)
VALUES ('ТехноПром', '+380000000000')
ON CONFLICT (name) DO NOTHING
RETURNING id;
-- Очікуваний результат: 0 рядків (INSERT 0 0): конфлікт за UNIQUE(name) мовчки ігноровано.

-- M6 [DELETE ... NOT EXISTS + RETURNING]: видалення скасованих оренд без позицій.
DELETE FROM rental.rentals AS r
WHERE r.status = 'cancelled'
  AND NOT EXISTS (SELECT 1 FROM rental.rental_items AS ri WHERE ri.rental_id = r.id)
RETURNING r.id, r.status;
-- Очікуваний результат: 12 | cancelled (DELETE 1). Оренда без позицій видаляється; оренда з
-- історією видалена бути не може (FOREIGN KEY ... ON DELETE RESTRICT) — див. тест T05.

ROLLBACK;   -- стан БД повернуто до початкового

-- Перевірка, що відкат скасував усі зміни частини Б
SELECT (SELECT COUNT(*) FROM rental.customers)  AS customers,   -- 8
       (SELECT COUNT(*) FROM rental.tools)      AS tools,       -- 16
       (SELECT COUNT(*) FROM rental.rentals)    AS rentals,     -- 12
       (SELECT COUNT(*) FROM rental.tool_audit) AS audit_rows;  -- 0
