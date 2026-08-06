"""A DAG whose single task always fails, for the airflow pack's behavior cases.

The failure path is what most of this pack is for — finding a failed task,
reading its log, and clearing it — so the fixture has to produce one reliably.
"""

from __future__ import annotations

import datetime

from airflow.sdk import dag, task

START_DATE = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)


@dag(
    dag_id="packtest_failing",
    description="Pack-test DAG whose task always raises.",
    schedule=None,
    start_date=START_DATE,
    catchup=False,
    tags=["packtest", "failure"],
)
def packtest_failing() -> None:
    @task(retries=0)
    def probe() -> None:
        raise RuntimeError("packtest deliberate failure")

    probe()


packtest_failing()
