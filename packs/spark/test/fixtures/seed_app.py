"""The short Spark application this pack's history-server cases read.

It runs to completion and leaves one finished application in the event log,
with a SQL execution and a shuffle — so the history server has more than a
single-stage job to report. Spark's own SparkPi example names itself, which is
why this fixture exists instead: the cases match on packtest-seed.
"""

from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("packtest-seed").getOrCreate()

spark.sql("SELECT 1 AS packtest_one").collect()

rows = spark.range(0, 1000).toDF("packtest_n")
rows.groupBy((rows.packtest_n % 10).alias("packtest_bucket")).count().collect()

spark.stop()
