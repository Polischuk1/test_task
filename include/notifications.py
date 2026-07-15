"""Slack failure alerting used as on_failure_callback by both DAGs.

Sends to the Slack Incoming Webhook stored in the `slack_default` connection.
Attaching this to default_args means any task failure — including the
data-quality gate — pages the team. (Airflow's notifier catches send errors
and logs them, so a broken webhook never crashes the task.)
"""
from __future__ import annotations

from airflow.providers.slack.notifications.slack_webhook import (
    send_slack_webhook_notification,
)

from include.config import SLACK_CONN_ID

failure_alert = send_slack_webhook_notification(
    slack_webhook_conn_id=SLACK_CONN_ID,
    text=(
        ":rotating_light: *LTV pipeline task failed*\n"
        "*DAG:* {{ dag.dag_id }}\n"
        "*Task:* {{ task_instance.task_id }}\n"
        "*Run:* {{ run_id }}  *When:* {{ ts }}\n"
        "<{{ task_instance.log_url }}|View logs>"
    ),
)
