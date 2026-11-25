Water Meter Readings and Billing
DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path TO q7_water;

(a) Tables
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10,2) NOT NULL,
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Alice'), ('Brian'), ('Grace');

(b) Function: tariff (first 10 units K5, above 10 units K8)
CREATE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Units must not be NULL or negative';
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql;

SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(15);  -- 0.00, 50.00, 90.00

(c) Procedure: generate a bill
CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC;
BEGIN
    SELECT current_reading - previous_reading INTO v_units
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading';
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading already has a bill';
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

(d) Trigger: reject current_reading below previous_reading
CREATE FUNCTION trg_reading_check_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading cannot be below previous reading';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check_fn();

(a) continued: 6 readings (0, 10 and above 10 units)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, '2026-09-01', 100, 100),   -- 0 units
(1, '2026-10-01', 100, 110),   -- 10 units
(2, '2026-09-01',  50,  65),   -- 15 units
(2, '2026-10-01',  65,  85),   -- 20 units
(3, '2026-10-01',   0,  10),   -- 10 units
(3, '2026-11-01',  10,  12);   -- 2 units

Bills through the procedure
CALL pr_generate_bill(1, '2026-11-10');
CALL pr_generate_bill(2, '2026-11-10');
CALL pr_generate_bill(3, '2026-11-10');
CALL pr_generate_bill(4, '2026-11-10');
CALL pr_generate_bill(5, '2026-11-20');
CALL pr_generate_bill(6, '2026-12-15');

Some payments
UPDATE bills SET amount_paid = 50 WHERE bill_id = 2;   -- fully paid
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;   -- part paid

SELECT * FROM bills;
-- Error tests: run each line alone
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--   VALUES (1, '2026-11-01', 100, 90);          -- trigger rejects, nothing stored
-- CALL pr_generate_bill(1, '2026-12-01');       -- already has a bill
-- CALL pr_generate_bill(99, '2026-12-01');      -- unknown reading

-- (e) View: overdue bills
CREATE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;   -- bills 3, 4 and 5

-- (f) Index: unpaid bills by due date
-- Justification: only unpaid bills matter, so a partial index on due_on is small
-- and finds overdue bills fast without reading the whole table.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;
SET enable_seqscan = on;

(g) Scheduled job: today's total unpaid balance
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();     -- rerun: still one row
SELECT * FROM receivable_snapshot; -- 240.00

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_receivables', '30 0 * * *',
    $$CALL q7_water.pr_refresh_receivables()$$);
SELECT * FROM cron.job;