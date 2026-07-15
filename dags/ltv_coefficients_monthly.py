"""
### LTV coefficients — monthly build

Recomputes the revenue-growth coefficients from the freshly-matured cohort
(users registered in `[kpi-5mo, kpi-3mo)`) and appends them to the
`coefficients` history table (one `kpi_dt` per month). Idempotent per month.

`kpi_dt` defaults to the run's logical date (`ds`); for a back-fill or to pin a
specific month, trigger with config, e.g. `{"kpi_dt": "2026-06-01"}`.

Downstream: the hourly forecast DAG reads this table.
"""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from airflow.models.dag import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

from include.config import POSTGRES_CONN_ID
from include.notifications import failure_alert

SQL_DIR = Path(__file__).resolve().parents[1] / "include" / "sql"

with DAG(
    dag_id="ltv_coefficients_monthly",
    description="Monthly rebuild of LTV growth coefficients",
    schedule="@monthly",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["ltv", "coefficients"],
    template_searchpath=[str(SQL_DIR)],
    default_args={"on_failure_callback": failure_alert},
    doc_md=__doc__,
) as dag:

    build_coefficients = SQLExecuteQueryOperator(
        task_id="build_coefficients",
        conn_id=POSTGRES_CONN_ID,
        sql="build_coefficients.sql",
        # any date in the target month; a manual trigger config can override `ds`
        parameters={"kpi_dt": "{{ dag_run.conf.get('kpi_dt') or ds }}"},
    )
