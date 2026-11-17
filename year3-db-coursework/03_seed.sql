-- =====================================================================
-- Файл 03: тестові дані (розділ 5.5 методичних рекомендацій)
-- Запускати після 01_schema.sql та 02_logic.sql.
--
-- Принцип: довідники заповнюються INSERT, а оренди, повернення та
-- обслуговування — викликами процедур. Тому тестові дані відображають
-- реальні процеси системи, а тригери й процедури перевіряються вже
-- під час наповнення.
--
-- Сценарії, закладені в даних:
--   * оренди, закриті вчасно (R1, R4, R6, R7, R8);
--   * оренди з простроченням і штрафом (R2, R3, R5);
--   * пошкодження при поверненні -> ремонт (R3, інструмент 11);
--   * відкриті оренди: у строк (R9, R11) та прострочена (R10);
--   * скасована оренда без позицій (R12);
--   * клієнт без оренд (7) і заблокований клієнт (8);
--   * списаний інструмент (16) та інструмент у ремонті (4) — обидва ще ніколи не орендувалися (запит Q03);
--   * інструмент, що неодноразово орендувався (9, 1) — для рейтингів і віконних функцій.
-- «Поточна дата» сценаріїв — 2026-11-11.
-- =====================================================================

-- ---------- Довідники ----------
INSERT INTO rental.suppliers (name, phone, email) VALUES
    ('ТехноПром',          '+380442001001', 'sales@tehnoprom.example'),
    ('БудМаркет Опт',      '+380442001002', 'opt@budmarket.example'),
    ('ГардЕн Інтернешнл',  '+380442001003', 'garden@intl.example'),
    ('Профі-Інструмент',   '+380442001004', 'info@profi-tool.example');

-- Категорії: три рівні вкладеності (для рекурсивного CTE)
INSERT INTO rental.categories (name, parent_id) VALUES
    ('Електроінструмент',       NULL),
    ('Будівельне обладнання',   NULL),
    ('Садова техніка',          NULL);

INSERT INTO rental.categories (name, parent_id)
SELECT v.name, p.id
FROM (VALUES ('Дрилі та перфоратори', 'Електроінструмент'),
             ('Шліфувальні машини',   'Електроінструмент'),
             ('Генератори',           'Будівельне обладнання'),
             ('Бетономішалки',        'Будівельне обладнання'),
             ('Газонокосарки та тримери', 'Садова техніка')) AS v(name, parent)
JOIN rental.categories AS p ON p.name = v.parent AND p.parent_id IS NULL;

INSERT INTO rental.categories (name, parent_id)
SELECT 'Акумуляторні шуруповерти', id FROM rental.categories WHERE name = 'Дрилі та перфоратори';

-- Інструменти. Статус усіх, окрім списаного, 'available'
-- (стани rented/maintenance виставляються тригерами та процедурами нижче).
INSERT INTO rental.tools
    (inventory_code, name, category_id, supplier_id, brand, model, daily_price, deposit_amount, purchase_date, status)
SELECT v.code, v.name,
       (SELECT id FROM rental.categories WHERE name = v.cat),
       (SELECT id FROM rental.suppliers  WHERE name = v.sup),
       v.brand, v.model, v.price, v.deposit, v.pdate::date, v.status
FROM (VALUES
 ('T-001','Перфоратор Bosch GBH 2-26',          'Дрилі та перфоратори',       'Профі-Інструмент','Bosch',     'GBH 2-26',   350.00, 2000.00,'2024-03-15','available'),
 ('T-002','Перфоратор Makita HR2470',           'Дрилі та перфоратори',       'Профі-Інструмент','Makita',    'HR2470',     300.00, 1800.00,'2024-05-20','available'),
 ('T-003','Шуруповерт DeWalt DCD777',           'Акумуляторні шуруповерти',   'Профі-Інструмент','DeWalt',    'DCD777',     200.00, 1200.00,'2025-01-10','available'),
 ('T-004','Шуруповерт Metabo BS 18',            'Акумуляторні шуруповерти',   'ТехноПром',       'Metabo',    'BS 18',      180.00, 1000.00,'2025-02-02','available'),
 ('T-005','Кутова шліфмашина Bosch GWS 750',    'Шліфувальні машини',         'Профі-Інструмент','Bosch',     'GWS 750',    150.00,  800.00,'2023-11-05','available'),
 ('T-006','Вібраційна шліфмашина Makita BO5041','Шліфувальні машини',         'ТехноПром',       'Makita',    'BO5041',     170.00,  900.00,'2024-08-12','available'),
 ('T-007','Бензогенератор Honda EU22i',         'Генератори',                 'БудМаркет Опт',   'Honda',     'EU22i',      900.00, 6000.00,'2023-06-01','available'),
 ('T-008','Генератор Hyundai HHY 3030',         'Генератори',                 'БудМаркет Опт',   'Hyundai',   'HHY 3030',   700.00, 4500.00,'2024-04-18','available'),
 ('T-009','Бетономішалка Lescha 160 л',         'Бетономішалки',              'БудМаркет Опт',   'Lescha',    '160',        400.00, 2500.00,'2024-07-07','available'),
 ('T-010','Бетономішалка Forte 125 л',          'Бетономішалки',              'БудМаркет Опт',   'Forte',     '125',        320.00, 2000.00,'2022-09-21','available'),
 ('T-011','Газонокосарка Husqvarna LC140',      'Газонокосарки та тримери',   'ГардЕн Інтернешнл','Husqvarna','LC140',      450.00, 3000.00,'2024-03-03','available'),
 ('T-012','Газонокосарка Gardena PowerMax',     'Газонокосарки та тримери',   'ГардЕн Інтернешнл','Gardena',  'PowerMax',   380.00, 2500.00,'2025-03-14','available'),
 ('T-013','Тример Stihl FS 38',                 'Газонокосарки та тримери',   'ГардЕн Інтернешнл','Stihl',    'FS 38',      250.00, 1500.00,'2025-04-01','available'),
 ('T-014','Мийка високого тиску Karcher K5',    'Садова техніка',             NULL,              'Karcher',   'K5',         330.00, 2000.00,'2024-09-09','available'),
 ('T-015','Лобзик Bosch PST 700',               'Електроінструмент',          'Профі-Інструмент','Bosch',     'PST 700',    120.00,  600.00,'2023-02-14','available'),
 ('T-016','Перфоратор «Зеніт» (списаний)',      'Дрилі та перфоратори',       NULL,              'Зеніт',     'ЗП-750',     100.00,  500.00,'2010-05-05','retired')
) AS v(code, name, cat, sup, brand, model, price, deposit, pdate, status);

INSERT INTO rental.customers (full_name, phone, email, discount_percent, is_blocked, registered_at) VALUES
    ('Іваненко Олег Петрович',  '+380501112233', 'oleg.ivanenko@example.com',   0,  false, '2026-08-20 12:00+03'),
    ('Коваленко Марія Іванівна','+380672223344', 'maria.kovalenko@example.com', 5,  false, '2026-08-25 15:30+03'),
    ('ТОВ «БудСервіс»',         '+380443334455', 'office@budservice.example',  10,  false, '2026-09-01 09:00+03'),
    ('Бондаренко Андрій',       '+380931112299', NULL,                          0,  false, '2026-09-05 11:10+03'),
    ('Мельник Ірина',           '+380632221100', 'irina.melnyk@example.com',    5,  false, '2026-09-30 17:45+03'),
    ('Ткаченко Василь',         '+380501239876', NULL,                          0,  false, '2026-10-10 10:00+03'),
    ('Савчук Наталія',          '+380991234567', 'natalia.savchuk@example.com', 0,  false, '2026-10-20 14:20+03'),
    ('Петренко Дмитро',         '+380671118899', NULL,                          0,  true,  '2026-09-12 13:00+03');

INSERT INTO rental.employees (full_name, position, email, hired_on, active) VALUES
    ('Лисенко Тарас',    'operator',   'lysenko@rental.example',   '2023-02-01', true),
    ('Гриценко Оксана',  'operator',   'hrytsenko@rental.example', '2024-06-15', true),
    ('Мороз Віктор',     'manager',    'moroz@rental.example',     '2022-01-10', true),
    ('Шапаренко Юрій',   'technician', 'shaparenko@rental.example','2023-09-01', true);

-- ---------- Операційні дані: оренди, повернення, обслуговування ----------
-- Виконується блоком DO: змінні зберігають id оренд, тому номери не прописано вручну.
DO $$
DECLARE
    v_r      integer;   -- id оренди (OUT p_rental_id)
    v_closed boolean;   -- OUT p_rental_closed
    v_log    bigint;    -- id запису обслуговування
    v_tool   integer;   -- OUT p_tool_id
BEGIN
    -- R1: вчасно, без знижки, дві позиції
    CALL rental.open_rental(1, 1, ARRAY[1,3], '2026-09-10 10:00+03', '2026-09-13 10:00+03', 'card', v_r);
    CALL rental.return_tool(v_r, 1, '2026-09-13 09:30+03', 'good', v_closed);
    CALL rental.return_tool(v_r, 3, '2026-09-13 09:30+03', 'good', v_closed);

    -- R2: прострочення на 1 добу 3 години (знижка 5%, штраф за 2 розпочаті доби)
    CALL rental.open_rental(2, 2, ARRAY[7], '2026-09-15 09:00+03', '2026-09-17 09:00+03', 'cash', v_r);
    CALL rental.return_tool(v_r, 7, '2026-09-18 12:00+03', 'good', v_closed);

    -- R3: три позиції, одна повернена із пошкодженням (->ремонт) і з простроченням
    CALL rental.open_rental(3, 1, ARRAY[9,10,11], '2026-09-20 08:00+03', '2026-09-27 08:00+03', 'transfer', v_r);
    CALL rental.return_tool(v_r, 9,  '2026-09-27 08:00+03', 'good',    v_closed);
    CALL rental.return_tool(v_r, 10, '2026-09-27 08:00+03', 'worn',    v_closed);
    CALL rental.return_tool(v_r, 11, '2026-09-28 10:00+03', 'damaged', v_closed);
    -- ремонт інструмента 11 (запис журналу створено тригером) завершено
    SELECT id INTO v_log FROM rental.maintenance_log WHERE tool_id = 11 AND finished_at IS NULL;
    CALL rental.finish_maintenance(v_log, 4, '2026-10-02 15:00+03', 850.00, v_tool);

    -- Планове обслуговування генератора
    CALL rental.start_maintenance(7, 4, '2026-09-19 09:00+03', 'Планова заміна масла та фільтрів', v_log);
    CALL rental.finish_maintenance(v_log, NULL, '2026-09-20 12:00+03', 300.00, v_tool);

    -- R4
    CALL rental.open_rental(1, 2, ARRAY[2,5], '2026-10-03 11:00+03', '2026-10-06 11:00+03', 'card', v_r);
    CALL rental.return_tool(v_r, 2, '2026-10-06 10:00+03', 'good', v_closed);
    CALL rental.return_tool(v_r, 5, '2026-10-06 10:00+03', 'good', v_closed);

    -- R5: прострочення на 9 годин
    CALL rental.open_rental(4, 1, ARRAY[8], '2026-10-08 09:00+03', '2026-10-10 09:00+03', 'cash', v_r);
    CALL rental.return_tool(v_r, 8, '2026-10-10 18:00+03', 'worn', v_closed);

    -- Обслуговування перфоратора між орендами
    CALL rental.start_maintenance(1, 4, '2026-10-10 09:00+03', 'Заміна вугільних щіток', v_log);
    CALL rental.finish_maintenance(v_log, NULL, '2026-10-11 16:00+03', 450.00, v_tool);

    -- R6
    CALL rental.open_rental(5, 2, ARRAY[12,13], '2026-10-12 10:00+03', '2026-10-14 10:00+03', 'card', v_r);
    CALL rental.return_tool(v_r, 12, '2026-10-14 10:00+03', 'good', v_closed);
    CALL rental.return_tool(v_r, 13, '2026-10-14 10:00+03', 'good', v_closed);

    -- R7
    CALL rental.open_rental(2, 1, ARRAY[1,6], '2026-10-15 09:00+03', '2026-10-19 09:00+03', 'card', v_r);
    CALL rental.return_tool(v_r, 1, '2026-10-19 08:00+03', 'good', v_closed);
    CALL rental.return_tool(v_r, 6, '2026-10-19 08:00+03', 'good', v_closed);

    -- R8: довга оренда (10 діб), повернення за 30 хв до строку
    CALL rental.open_rental(3, 1, ARRAY[9], '2026-10-14 09:00+03', '2026-10-24 09:00+03', 'transfer', v_r);
    CALL rental.return_tool(v_r, 9, '2026-10-24 07:30+03', 'good', v_closed);

    -- Відкриті оренди (з 25.10.2026 в Україні діє зимовий час, +02)
    CALL rental.open_rental(1, 1, ARRAY[3,15], '2026-11-07 10:00+02', '2026-11-14 10:00+02', 'card', v_r);  -- R9: у строк
    CALL rental.open_rental(6, 2, ARRAY[11],   '2026-10-28 09:00+02', '2026-11-04 09:00+02', 'cash', v_r);  -- R10: прострочена
    CALL rental.open_rental(3, 1, ARRAY[10,14],'2026-11-09 08:00+02', '2026-11-12 08:00+02', 'transfer', v_r); -- R11: строк завтра

    -- Інструмент 4 зараз на обслуговуванні
    CALL rental.start_maintenance(4, 4, '2026-11-05 09:00+02', 'Заміна акумуляторної батареї', v_log);
END;
$$;

-- R12: скасована оренда (позицій немає) — приклад для DELETE
INSERT INTO rental.rentals (customer_id, employee_id, rented_at, due_at, status)
VALUES (5, 1, '2026-11-10 12:00+02', '2026-11-12 12:00+02', 'cancelled');

-- Швидка перевірка наповнення
SELECT 'suppliers' AS tbl, COUNT(*) FROM rental.suppliers
UNION ALL SELECT 'categories',      COUNT(*) FROM rental.categories
UNION ALL SELECT 'tools',           COUNT(*) FROM rental.tools
UNION ALL SELECT 'customers',       COUNT(*) FROM rental.customers
UNION ALL SELECT 'employees',       COUNT(*) FROM rental.employees
UNION ALL SELECT 'rentals',         COUNT(*) FROM rental.rentals
UNION ALL SELECT 'rental_items',    COUNT(*) FROM rental.rental_items
UNION ALL SELECT 'payments',        COUNT(*) FROM rental.payments
UNION ALL SELECT 'maintenance_log', COUNT(*) FROM rental.maintenance_log
UNION ALL SELECT 'tool_audit',      COUNT(*) FROM rental.tool_audit;
