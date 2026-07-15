"""
### LTV 3-month forecast — hourly refresh

Every hour:
1. **quality_checks** — loads each user's latest `forecast_1m` + attributes and
   validates the batch (nulls, orphans, value range, freshness, and that
   coefficients exist for each registration month). On any failure it raises,
   so the upsert below is skipped (nothing written) and Slack is paged.
2. **upsert_forecasts** — computes `forecast_3m = forecast_1m * (1 + coeff)`
   using the current `coefficients` table (with the reliability fallback) and
   upserts one row per user into `user_forecast_3m`.

Coefficients are produced by the separate `ltv_coefficients_monthly` DAG.
"""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from airflow.decorators import task
from airflow.models.dag import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

from include.config import (
    FORECAST_MAX_USD,
    FORECAST_STALE_HOURS,
    MIN_BATCH_ROWS,
    POSTGRES_CONN_ID,
)
from include.notifications import failure_alert
from include.quality_checks import run_quality_checks

SQL_DIR = Path(__file__).resolve().parents[1] / "include" / "sql"

with DAG(
    dag_id="ltv_forecast_hourly",
    description="Hourly refresh of per-user 3-month LTV forecasts",
    schedule="@hourly",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["ltv", "forecast"],
    template_searchpath=[str(SQL_DIR)],
    default_args={"on_failure_callback": failure_alert},
    doc_md=__doc__,
) as dag:

    @task(task_id="quality_checks")
    def quality_checks() -> dict:
        """Gate the run on data quality; raises AirflowException on failure."""
        return run_quality_checks(
            postgres_conn_id=POSTGRES_CONN_ID,
            max_usd=FORECAST_MAX_USD,
            stale_hours=FORECAST_STALE_HOURS,
            min_rows=MIN_BATCH_ROWS,
        )

    upsert_forecasts = SQLExecuteQueryOperator(
        task_id="upsert_forecasts",
        conn_id=POSTGRES_CONN_ID,
        sql="upsert_forecast_3m.sql",
    )

    quality_checks() >> upsert_forecasts
