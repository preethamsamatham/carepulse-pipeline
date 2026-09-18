import sys
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from pyspark.context import SparkContext 
from awsglue.job import Job

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'TABLE_NAME'])
sc= SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)
table_name = args['TABLE_NAME']
source_path = f"s3://carepulse-raw-preetham-2026/{table_name}.csv"
output_path = f"s3://carepulse-raw-preetham-2026/curated/{table_name}/"

df = spark.read.option("header", "true").csv(source_path)
df.repartition(1).write.mode("overwrite").parquet(output_path)

job.commit()