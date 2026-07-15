"""Pre-computation data-quality checks for the hourly forecast DAG.

Ported from forecast_pipeline.py's validate(). Loads the batch that is about to
be forecast (each user's latest forecast_1m + attributes) and runs a set of
checks. If ANY check fails it raises AirflowException, which fails the
`quality_checks` task -> the downstream upsert is skipped (nothing written) and
the DAG's on_failure_callback pages the team on Slack.
"""
from __future__ import annotations

from datetime import datetime

from airflow.exceptions import AirflowException
from airflow.providers.postgres.hooks.postgres import PostgresHook
from psycopg2.extras import RealDictCursor

LOAD_BATCH_SQL = """
    WITH latest_forecast AS (
        SELECT DISTINCT ON (user_id) user_id, forecast_1m_usd, calc_dt
        FROM forecast_1m
        ORDER BY user_id, calc_dt::timestamp DESC
    )
    SELECT lf.user_id,
           lf.forecast_1m_usd,
           lf.calc_dt::timestamp                                  AS calc_dt,
           u.country, u.age_group, u.gender,
           DATE_TRUNC('month', u.registered_at::timestamp)::date  AS reg_month
    FROM latest_forecast lf
    LEFT JOIN users u USING (user_id);
"""


def _load_batch(conn) -> list[dict]:
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(LOAD_BATCH_SQL)
        return [dict(r) for r in cur.fetchall()]


def _validate(rows: list[dict], conn, max_usd: float, stale_hours: float, min_rows: int) -> list[str]:
    failures: list[str] = []

    if len(rows) < min_rows:
        return [f"Batch too small: {len(rows)} users (< MIN_BATCH_ROWS={min_rows})."]

    for field in ("forecast_1m_usd", "calc_dt", "country", "age_group", "gender", "reg_month"):
        bad = [r["user_id"] for r in rows if r.get(field) is None]
        if bad:
            failures.append(f"{len(bad)} users have NULL '{field}' (e.g. {bad[:5]}).")

    orphans = [r["user_id"] for r in rows if r.get("reg_month") is None]
    if orphans:
        failures.append(f"{len(orphans)} forecasted users are missing from the users table (e.g. {orphans[:5]}).")

    negative = [r["user_id"] for r in rows if r.get("forecast_1m_usd") is not None and r["forecast_1m_usd"] < 0]
    if negative:
        failures.append(f"{len(negative)} users have a negative forecast_1m_usd (e.g. {negative[:5]}).")

    huge = [r["user_id"] for r in rows
            if r.get("forecast_1m_usd") is not None and r["forecast_1m_usd"] > max_usd]
    if huge:
        failures.append(f"{len(huge)} users exceed FORECAST_MAX_USD={max_usd} (e.g. {huge[:5]}).")

    calc_dts = [r["calc_dt"] for r in rows if r.get("calc_dt") is not None]
    if calc_dts:
        newest = max(calc_dts)
        age_h = (datetime.now() - newest).total_seconds() / 3600.0
        if age_h > stale_hours:
            failures.append(
                f"Upstream forecast_1m is stale: newest calc_dt {newest} is {age_h:.1f}h old "
                f"(> STALE_HOURS={stale_hours}). Is the 1-month model running?"
            )

    # coefficients must exist for every registration month present in the batch,
    # each with an all-users fallback that has >= 100 buyers (guarantees a match)
    reg_months = sorted({r["reg_month"] for r in rows if r.get("reg_month") is not None})
    with conn.cursor() as cur:
        for kpi in reg_months:
            cur.execute(
                """
                SELECT COUNT(*),
                       COUNT(*) FILTER (WHERE country='' AND age_group='' AND gender='' AND buyers >= 100)
                FROM coefficients WHERE kpi_dt = %s
                """,
                (kpi,),
            )
            n_rows, has_fallback = cur.fetchone()
            if n_rows == 0:
                failures.append(f"No coefficients for kpi_dt={kpi} (users registered that month can't be scored).")
            elif not has_fallback:
                failures.append(f"coefficients[{kpi}] has no all-users fallback with >=100 buyers.")

    return failures


def run_quality_checks(postgres_conn_id: str, max_usd: float, stale_hours: float, min_rows: int) -> dict:
    """Run all checks; raise AirflowException on any failure, else return a summary."""
    hook = PostgresHook(postgres_conn_id=postgres_conn_id)
    conn = hook.get_conn()
    try:
        rows = _load_batch(conn)
        failures = _validate(rows, conn, max_usd, stale_hours, min_rows)
    finally:
        conn.close()

    if failures:
        raise AirflowException(
            "Data-quality checks FAILED — forecast not updated:\n"
            + "\n".join(f"  - {f}" for f in failures)
        )
    return {"users_to_forecast": len(rows)}
