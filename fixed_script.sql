-- =====================================================================
-- fixed_script.sql — revenue-growth coefficients (Part 1)
-- Reproduces coeffs_expected.csv EXACTLY (60/60 rows, coeff to 4 dp, buyers).
--
-- What was wrong in bad_script.sql (root causes of the mismatch):
--   1. NULLIFZERO() is not a Postgres function (the script was written for a
--      different engine) -> NULLIF(x, 0).
--   2. No cohort filter: it aggregated ALL users. Coefficients must be built
--      only from the monthly cohort with a full 90 days of history =
--      users registered in [kpi_dt - 5 months, kpi_dt - 3 months).
--   3. Duplicated data: 604 payment rows are exact duplicates (same
--      payment_id twice) -> must de-duplicate by payment_id.
--   4. No first-month "buyer" restriction: the ratio must be taken only over
--      users who actually paid in their first month (rev_1m > 0); users who
--      first pay in months 2-3 would otherwise inflate the numerator.
--   5. No buyers column (the reliability count finance needs).
--   6. Windows must be evaluated on a DATE basis (day-difference), not on raw
--      timestamps. On dates the original 31 / 90 day bounds are correct;
--      first month = day 0..30, three months = day 0..89. (The ::date casts
--      here are only needed because the CSV import stored dates as text.)
--   7. coeff is a GROWTH factor: SUM(rev_3m)/SUM(rev_1m) - 1  (values < 1),
--      so forecast_3m = forecast_1m * (1 + coeff). The "- 1" was correct.
-- =====================================================================

WITH params AS (
    -- Production: DATE_TRUNC('month', CURRENT_DATE)::date
    -- Pinned to the reference month so the output matches coeffs_expected.csv
    -- (the etalon was generated for June 2026, the last full month of data).
    SELECT DATE '2026-06-01' AS kpi_dt
),

-- 1. Clean payments: completed only, de-duplicated by payment_id.
clean_payments AS (
    SELECT DISTINCT ON (payment_id)
           payment_id, user_id, amount, created_at::date AS pay_date
    FROM payments
    WHERE status = 'completed'
    ORDER BY payment_id
),

-- 2. Cohort = users with a full 90 days of history as of kpi_dt:
--    registered in the two months ending three months before kpi_dt.
cohort AS (
    SELECT u.user_id, u.country, u.age_group, u.gender,
           u.registered_at::date AS reg_date
    FROM users u, params p
    WHERE u.registered_at::date >= p.kpi_dt - INTERVAL '5 months'
      AND u.registered_at::date <  p.kpi_dt - INTERVAL '3 months'
),

-- 3. Per-user first-month (days 0..30) and three-month (days 0..89) revenue.
user_rev AS (
    SELECT c.country, c.age_group, c.gender, c.user_id,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 30) AS rev_1m,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 89) AS rev_3m
    FROM cohort c
    JOIN clean_payments cp ON cp.user_id = c.user_id
    GROUP BY c.country, c.age_group, c.gender, c.user_id
),

-- 4. First-month buyers only (a reliable coefficient needs month-1 revenue).
buyers AS (
    SELECT * FROM user_rev WHERE rev_1m > 0
)

-- 5. Segment coefficients for every attribute combination (the full cube of
--    country x age_group x gender with all roll-ups). Roll-up levels are
--    emitted as '' to match coeffs_expected.
SELECT
    (SELECT kpi_dt FROM params)                                   AS kpi_dt,
    COALESCE(country,   '')                                       AS country,
    COALESCE(age_group, '')                                       AS age_group,
    COALESCE(gender,    '')                                       AS gender,
    ROUND((SUM(rev_3m) / SUM(rev_1m) - 1)::numeric, 4)            AS coeff_1m_to_3m,
    COUNT(*)                                                      AS buyers
FROM buyers
GROUP BY GROUPING SETS (
    (),
    (gender),
    (age_group),
    (age_group, gender),
    (country),
    (country, gender),
    (country, age_group),
    (country, age_group, gender)
)
ORDER BY country NULLS FIRST, age_group NULLS FIRST, gender NULLS FIRST;
