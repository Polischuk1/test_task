-- upsert_forecast_3m.sql — HOURLY job. Refresh every user's 3-month forecast
-- from their latest forecast_1m and the current coefficients table.
--   forecast_3m_usd = forecast_1m_usd * (1 + coeff_1m_to_3m)
-- Coefficient selection: the most specific segment (>= 100 buyers) matching the
-- user, tie-broken by priority country > age_group > gender. Same logic as
-- forecast_script.sql, but reads the stored coefficients table and upserts.

CREATE TABLE IF NOT EXISTS user_forecast_3m (
    user_id         varchar PRIMARY KEY,
    forecast_1m_usd real,
    coeff_1m_to_3m  real,
    forecast_3m_usd real,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO user_forecast_3m (user_id, forecast_1m_usd, coeff_1m_to_3m, forecast_3m_usd, updated_at)
WITH latest_forecast AS (
    SELECT DISTINCT ON (user_id) user_id, forecast_1m_usd
    FROM forecast_1m
    ORDER BY user_id, calc_dt::timestamp DESC
),
user_attr AS (
    SELECT lf.user_id, lf.forecast_1m_usd, u.country, u.age_group, u.gender,
           DATE_TRUNC('month', u.registered_at::timestamp)::date AS reg_month
    FROM latest_forecast lf
    JOIN users u USING (user_id)
),
matched AS (
    SELECT ua.user_id, ua.forecast_1m_usd, c.coeff_1m_to_3m,
           ROW_NUMBER() OVER (
               PARTITION BY ua.user_id
               ORDER BY ( (c.country<>'')::int + (c.age_group<>'')::int + (c.gender<>'')::int ) DESC,
                        ( 4*(c.country<>'')::int + 2*(c.age_group<>'')::int + (c.gender<>'')::int ) DESC,
                        c.buyers DESC
           ) AS rn
    FROM user_attr ua
    JOIN coefficients c
      ON c.kpi_dt = ua.reg_month AND c.buyers >= 100
     AND (c.country   = ua.country   OR c.country   = '')
     AND (c.age_group = ua.age_group OR c.age_group = '')
     AND (c.gender    = ua.gender    OR c.gender    = '')
)
SELECT user_id, forecast_1m_usd, coeff_1m_to_3m,
       ROUND((forecast_1m_usd * (1 + coeff_1m_to_3m))::numeric, 2)::real,
       now()
FROM matched
WHERE rn = 1
ON CONFLICT (user_id) DO UPDATE
    SET forecast_1m_usd = EXCLUDED.forecast_1m_usd,
        coeff_1m_to_3m  = EXCLUDED.coeff_1m_to_3m,
        forecast_3m_usd = EXCLUDED.forecast_3m_usd,
        updated_at      = EXCLUDED.updated_at;
