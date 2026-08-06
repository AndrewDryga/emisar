"""The long-running Spark application this pack's live-driver cases read.

It produces, in order, the four things those cases need from a driver UI: a SQL
execution, a cached RDD in storage, executors registered against the standalone
master, and a job that never finishes on its own — the one spark.job_kill and
spark.stage_kill cancel. The kill is expected, so the loop catches the
cancellation and starts another long job, which keeps the driver, its
application id, and its UI alive for the probe that reads the outcome back.
"""

import time

from pyspark.sql import SparkSession

LONG_SLEEP_SECONDS = 3600
PARTITIONS = 8

spark = SparkSession.builder.appName("packtest-live").getOrCreate()
context = spark.sparkContext

# One SQL execution, for the /sql endpoints.
spark.sql("SELECT 1 AS packtest_one").collect()

# One cached dataset, for /storage/rdd.
cached = spark.range(0, 1000).toDF("packtest_n")
cached.cache()
cached.count()

while True:
    context.setJobDescription("packtest-long-job")
    try:
        context.parallelize(range(PARTITIONS), PARTITIONS).map(
            lambda _: time.sleep(LONG_SLEEP_SECONDS)
        ).collect()
    except Exception:  # the job or its stage was killed, which is the point
        time.sleep(2)
