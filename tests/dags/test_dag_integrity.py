"""DAG integrity test — run with `astro dev pytest`.

Loads every DAG and asserts there are no import errors and the expected DAGs
exist with the right schedules. Catches broken imports/typos before deploy.
"""
from __future__ import annotations

from airflow.models import DagBag

EXPECTED = {
    "ltv_coefficients_monthly": "@monthly",
    "ltv_forecast_hourly": "@hourly",
}


def test_no_import_errors():
    dagbag = DagBag(include_examples=False)
    assert dagbag.import_errors == {}, f"DAG import errors: {dagbag.import_errors}"


def test_expected_dags_present():
    dagbag = DagBag(include_examples=False)
    for dag_id, schedule in EXPECTED.items():
        dag = dagbag.get_dag(dag_id)
        assert dag is not None, f"missing DAG: {dag_id}"
        assert str(dag.schedule_interval) == schedule or dag.timetable.summary == schedule
