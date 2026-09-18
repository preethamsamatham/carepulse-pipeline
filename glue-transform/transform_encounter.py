# Superseded by transform_table.py — kept to show the parameterization refactor.
# This version hardcoded "encounters" as the table name; transform_table.py
# generalizes this to accept any table via the TABLE_NAME job argument.
import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(sys.argv, ["JOB_NAME"])
sc = SparkContext()
gluecontext = GlueContext(sc)
spark = gluecontext.spark_session
job = Job(gluecontext)
job.init(args["JOB_NAME"], args)

# --- The actual transform: deliberately minimal ---
df = spark.read.option("header", "true").csv(
    "s3://carepulse-raw-preetham-2026/encounters.csv"
)

df.repartition(1).write.mode("overwrite").parquet(
    "s3://carepulse-raw-preetham-2026/curated/encounters/"
)

job.commit()