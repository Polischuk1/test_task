-- Storage for the pipeline. Both DAGs also create their table with
-- CREATE TABLE IF NOT EXISTS, so this file is only needed for manual setup.

CREATE TABLE IF NOT EXISTS coefficients (
    kpi_dt         date    NOT NULL,
    country        varchar NOT NULL DEFAULT '',
    age_group      varchar NOT NULL DEFAULT '',
    gender         varchar NOT NULL DEFAULT '',
    coeff_1m_to_3m real,
    buyers         integer,
    PRIMARY KEY (kpi_dt, country, age_group, gender)
);

CREATE TABLE IF NOT EXISTS user_forecast_3m (
    user_id         varchar PRIMARY KEY,
    forecast_1m_usd real,
    coeff_1m_to_3m  real,
    forecast_3m_usd real,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
