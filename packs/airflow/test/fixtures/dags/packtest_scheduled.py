"""A scheduled DAG for the airflow pack's backfill cases.

Airflow refuses a backfill on a DAG with no periodic schedule, so the backfill
cases need one with a cron timetable. It arrives paused so its own scheduled
runs never compete with the assertions the other cases make — creating,
pausing, and cancelling a backfill all work while the DAG is paused.
"""

from __future__ import annotations

import datetime

from airflow.sdk import dag, task

START_DATE = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)


@dag(
    dag_id="packtest_scheduled",
    description="Pack-test DAG with a daily schedule, paused on creation.",
    schedule="@daily",
    start_date=START_DATE,
    catchup=False,
    is_paused_upon_creation=True,
    tags=["packtest", "scheduled"],
)
def packtest_scheduled() -> None:
    @task
    def report() -> None:
        print("packtest scheduled report complete")

    report()


packtest_scheduled()
