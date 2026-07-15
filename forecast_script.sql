-- =====================================================================
-- forecast_script.sql — 3-month LTV forecast per user (Part 2)
-- For every user in forecast_1m: take the latest 1-month forecast, find the
-- applicable growth coefficient, and project 3-month revenue.
--
-- Output: user_id, forecast_1m_usd, coeff_1m_to_3m, forecast_3m_usd
--   forecast_3m_usd = forecast_1m_usd * (1 + coeff_1m_to_3m)
--   (coeff is a growth factor = rev_3m/rev_1m - 1, so the multiplier is 1+coeff)
--
-- Coefficient selection:
--   * coefficients are looked up for the user's REGISTRATION month
--     (DATE_TRUNC('month', registered_at) = coefficients.kpi_dt);
--   * a coefficient is only trusted when its segment has >= 100 buyers;
--   * use the most specific segment that matches the user on the greatest
--     number of attributes and still has >= 100 buyers, falling back through
--     country+age+gender -> ... -> the all-users coefficient.
-- =====================================================================

WITH
-- ---- coefficients ----------------------------------------------------
-- In production this is the stored coefficients table (accumulated monthly
-- by fixed_script.sql, one kpi_dt per month). It is inlined here so the
-- script runs standalone; replace this CTE with:  SELECT * FROM coefficients
params AS (
    SELECT DATE '2026-06-01' AS kpi_dt   -- production: DATE_TRUNC('month', CURRENT_DATE)::date
),
clean_payments AS (
    SELECT DISTINCT ON (payment_id)
           payment_id, user_id, amount, created_at::date AS pay_date
    FROM payments
    WHERE status = 'completed'
    ORDER BY payment_id
),
cohort AS (
    SELECT u.user_id, u.country, u.age_group, u.gender, u.registered_at::date AS reg_date
    FROM users u, params p
    WHERE u.registered_at::date >= p.kpi_dt - INTERVAL '5 months'
      AND u.registered_at::date <  p.kpi_dt - INTERVAL '3 months'
),
user_rev AS (
    SELECT c.country, c.age_group, c.gender, c.user_id,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 30) AS rev_1m,
           SUM(cp.amount) FILTER (WHERE cp.pay_date - c.reg_date BETWEEN 0 AND 89) AS rev_3m
    FROM cohort c
    JOIN clean_payments cp ON cp.user_id = c.user_id
    GROUP BY c.country, c.age_group, c.gender, c.user_id
),
coefficients AS (
    SELECT
        (SELECT kpi_dt FROM params)                          AS kpi_dt,
        COALESCE(country,   '')                              AS country,
        COALESCE(age_group, '')                              AS age_group,
        COALESCE(gender,    '')                              AS gender,
        ROUND((SUM(rev_3m) / SUM(rev_1m) - 1)::numeric, 4)   AS coeff_1m_to_3m,
        COUNT(*)                                             AS buyers
    FROM user_rev
    WHERE rev_1m > 0
    GROUP BY GROUPING SETS (
        (), (gender), (age_group), (age_group, gender),
        (country), (country, gender), (country, age_group), (country, age_group, gender)
    )
),

-- ---- forecast inputs -------------------------------------------------
-- The current 1-month forecast for each user = the last row by calc_dt.
latest_forecast AS (
    SELECT DISTINCT ON (user_id)
           user_id, forecast_1m_usd
    FROM forecast_1m
    ORDER BY user_id, calc_dt::timestamp DESC
),
user_attr AS (
    SELECT lf.user_id, lf.forecast_1m_usd,
           u.country, u.age_group, u.gender,
           DATE_TRUNC('month', u.registered_at::timestamp)::date AS reg_month
    FROM latest_forecast lf
    JOIN users u USING (user_id)
),

-- ---- coefficient match with reliability fallback ---------------------
matched AS (
    SELECT
        ua.user_id, ua.forecast_1m_usd, c.coeff_1m_to_3m,
        ROW_NUMBER() OVER (
            PARTITION BY ua.user_id
            ORDER BY
                -- 1) most attributes matched wins (max number of attributes)
                ( (c.country<>'')::int + (c.age_group<>'')::int + (c.gender<>'')::int ) DESC,
                -- 2) tie-break within the same count: keep the higher-priority
                --    attributes. The spec example drops gender first (keeps
                --    country+age), i.e. priority country > age_group > gender.
                ( 4*(c.country<>'')::int + 2*(c.age_group<>'')::int + (c.gender<>'')::int ) DESC,
                -- 3) final deterministic guard (not expected to be needed)
                c.buyers DESC
        ) AS rn
    FROM user_attr ua
    JOIN coefficients c
      ON c.kpi_dt = ua.reg_month
     AND c.buyers >= 100
     AND (c.country   = ua.country   OR c.country   = '')
     AND (c.age_group = ua.age_group OR c.age_group = '')
     AND (c.gender    = ua.gender    OR c.gender    = '')
)
SELECT
    user_id,
    forecast_1m_usd,
    coeff_1m_to_3m,
    ROUND((forecast_1m_usd * (1 + coeff_1m_to_3m))::numeric, 2) AS forecast_3m_usd
FROM matched
WHERE rn = 1
ORDER BY user_id;
