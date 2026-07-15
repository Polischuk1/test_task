-- build_coefficients.sql — MONTHLY job. Rebuild the growth coefficients for the
-- cohort and append them to the coefficients history table.
--
-- Parametrised by %(kpi_dt)s (any date within the target month; it is truncated
-- to the month). Idempotent: it replaces only that month's rows, so scheduled
-- runs and back-fills are both safe. Logic is identical to fixed_script.sql.

CREATE TABLE IF NOT EXISTS coefficients (
    kpi_dt         date    NOT NULL,
    country        varchar NOT NULL DEFAULT '',
    age_group      varchar NOT NULL DEFAULT '',
    gender         varchar NOT NULL DEFAULT '',
    coeff_1m_to_3m real,
    buyers         integer,
    PRIMARY KEY (kpi_dt, country, age_group, gender)
);

DELETE FROM coefficients
WHERE kpi_dt = DATE_TRUNC('month', %(kpi_dt)s::date)::date;

INSERT INTO coefficients (kpi_dt, country, age_group, gender, coeff_1m_to_3m, buyers)
WITH kpi AS (
    SELECT DATE_TRUNC('month', %(kpi_dt)s::date)::date AS kpi_dt
),
-- completed payments, de-duplicated by payment_id
clean_payments AS (
    SELECT DISTINCT ON (payment_id)
           payment_id, user_id, amount, created_at::date AS pay_date
    FROM payments
    WHERE status = 'completed'
    ORDER BY payment_id
),
-- cohort with a full 90 days of history: registered in [kpi-5mo, kpi-3mo)
cohort AS (
    SELECT u.user_id, u.country, u.age_group, u.gender, u.registered_at::date AS reg_date
    FROM users u, kpi
    WHERE u.registered_at::date >= kpi.kpi_dt - INTERVAL '5 months'
      AND u.registered_at::date <  kpi.kpi_dt - INTERVAL '3 months'
),
-- per-user first-month (day 0..30) and three-month (day 0..89) revenue, date-based
user_rev AS (
    SELECT c.country, c.age_group, c.gender, c.user_id,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 30) AS rev_1m,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 89) AS rev_3m
    FROM cohort c
    JOIN clean_payments cp ON cp.user_id = c.user_id
    GROUP BY c.country, c.age_group, c.gender, c.user_id
)
SELECT
    (SELECT kpi_dt FROM kpi),
    COALESCE(country,   ''),
    COALESCE(age_group, ''),
    COALESCE(gender,    ''),
    ROUND((SUM(rev_3m) / SUM(rev_1m) - 1)::numeric, 4)::real,
    COUNT(*)
FROM user_rev
WHERE rev_1m > 0            -- first-month buyers only
GROUP BY GROUPING SETS (
    (), (gender), (age_group), (age_group, gender),
    (country), (country, gender), (country, age_group), (country, age_group, gender)
);
