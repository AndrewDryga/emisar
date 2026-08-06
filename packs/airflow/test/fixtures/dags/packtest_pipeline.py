"""A two-task DAG that succeeds, for the airflow pack's behavior cases.

Deliberately trivial: the cases assert on run and task-instance state, log
content, and clear behavior, so the work itself only has to be deterministic
and fast.
"""

from __future__ import annotations

import datetime

from airflow.sdk import dag, task

START_DATE = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)


@dag(
    dag_id="packtest_pipeline",
    description="Pack-test pipeline that extracts and loads.",
    schedule=None,
    start_date=START_DATE,
    catchup=False,
    tags=["packtest", "pipeline"],
)
def packtest_pipeline() -> None:
    @task
    def extract() -> int:
        print("packtest extract complete")
        return 7

    @task
    def load(rows: int) -> None:
        print(f"packtest load complete rows={rows}")

    load(extract())


packtest_pipeline()
