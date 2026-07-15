"""Shared configuration for the LTV DAGs (connections + quality thresholds).

All values can be overridden with environment variables set on the Astro
deployment (or the local `.env`), so the same code runs against dev and prod.
"""
from __future__ import annotations

import os

# Airflow connection ids (create these in the deployment / airflow_settings.yaml)
POSTGRES_CONN_ID = os.getenv("LTV_POSTGRES_CONN_ID", "postgres_ltv")
SLACK_CONN_ID = os.getenv("LTV_SLACK_CONN_ID", "slack_default")

# Data-quality thresholds
FORECAST_MAX_USD = float(os.getenv("FORECAST_MAX_USD", "100000"))     # reject absurd forecasts
FORECAST_STALE_HOURS = float(os.getenv("FORECAST_STALE_HOURS", "26")) # newest forecast must be fresher
MIN_BATCH_ROWS = int(os.getenv("MIN_BATCH_ROWS", "1"))               # min users to forecast
