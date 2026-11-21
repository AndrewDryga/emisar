"""A two-task DAG that succeeds, for the airflow pack's behavior cases.

Deliberately trivial: the cases assert on run and task-instance state, log
content, and clear behavior, so the work itself only has to be deterministic
and fast. The load task updates one asset, so the seeded successful run leaves
an asset event behind for the asset cases.
"""

from __future__ import annotations

import datetime

try:
    from airflow.sdk import Asset, dag, task
except ImportError:
    from airflow.datasets import Dataset as Asset
    from airflow.decorators import dag, task

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

    @task(outlets=[Asset("packtest_orders")])
    def load(rows: int) -> None:
        print(f"packtest load complete rows={rows}")

    load(extract())

    @task
    def mapped(value: int) -> int:
        return value

    mapped.expand(value=[1, 2])


packtest_pipeline()
