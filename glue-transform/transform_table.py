import sys
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from pyspark.context import SparkContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType, DoubleType,
    DecimalType, DateType, TimestampType,
)

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'TABLE_NAME'])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Synthea timestamps end in "Z" (UTC). Pin the session to UTC so Spark never
# silently shifts them into the worker's local timezone.
spark.conf.set("spark.sql.session.timeZone", "UTC")

table_name = args['TABLE_NAME']
source_path = f"s3://carepulse-raw-preetham-2026/{table_name}.csv"
output_path = f"s3://carepulse-raw-preetham-2026/curated/{table_name}/"

# --- Schemas: config, not code (same idea as EXPECTED_COLUMNS in validate.py) ---
# Field ORDER must match the CSV header exactly; enforceSchema=false below
# makes Spark verify that instead of silently mapping by position.
S = StringType()
MONEY = DecimalType(14, 2)   # exact cents; Double would introduce float rounding
TS = TimestampType()
D = DateType()

def schema(*fields):
    return StructType([StructField(name, dtype, True) for name, dtype in fields])

SCHEMAS = {
    "patients": schema(
        ("Id", S), ("BIRTHDATE", D), ("DEATHDATE", D), ("SSN", S), ("DRIVERS", S),
        ("PASSPORT", S), ("PREFIX", S), ("FIRST", S), ("MIDDLE", S), ("LAST", S),
        ("SUFFIX", S), ("MAIDEN", S), ("MARITAL", S), ("RACE", S), ("ETHNICITY", S),
        ("GENDER", S), ("BIRTHPLACE", S), ("ADDRESS", S), ("CITY", S), ("STATE", S),
        ("COUNTY", S), ("FIPS", S), ("ZIP", S),          # codes, not numbers: ZIP "01086"
        ("LAT", DoubleType()), ("LON", DoubleType()),
        ("HEALTHCARE_EXPENSES", MONEY), ("HEALTHCARE_COVERAGE", MONEY),
        ("INCOME", IntegerType()),
    ),
    "encounters": schema(
        ("Id", S), ("START", TS), ("STOP", TS), ("PATIENT", S), ("ORGANIZATION", S),
        ("PROVIDER", S), ("PAYER", S), ("ENCOUNTERCLASS", S), ("CODE", S),
        ("DESCRIPTION", S), ("BASE_ENCOUNTER_COST", MONEY), ("TOTAL_CLAIM_COST", MONEY),
        ("PAYER_COVERAGE", MONEY), ("REASONCODE", S), ("REASONDESCRIPTION", S),
    ),
    "conditions": schema(                                  # date-only, unlike the rest
        ("START", D), ("STOP", D), ("PATIENT", S), ("ENCOUNTER", S),
        ("SYSTEM", S), ("CODE", S), ("DESCRIPTION", S),
    ),
    "medications": schema(
        ("START", TS), ("STOP", TS), ("PATIENT", S), ("PAYER", S), ("ENCOUNTER", S),
        ("CODE", S), ("DESCRIPTION", S), ("BASE_COST", MONEY), ("PAYER_COVERAGE", MONEY),
        ("DISPENSES", IntegerType()), ("TOTALCOST", MONEY),
        ("REASONCODE", S), ("REASONDESCRIPTION", S),
    ),
    "procedures": schema(
        ("START", TS), ("STOP", TS), ("PATIENT", S), ("ENCOUNTER", S), ("SYSTEM", S),
        ("CODE", S), ("DESCRIPTION", S), ("BASE_COST", MONEY),
        ("REASONCODE", S), ("REASONDESCRIPTION", S),
    ),
    "observations": schema(
        ("DATE", TS), ("PATIENT", S), ("ENCOUNTER", S), ("CATEGORY", S), ("CODE", S),
        ("DESCRIPTION", S), ("VALUE", S),                  # mixed numeric/text -> stays string
        ("UNITS", S), ("TYPE", S),
    ),
}

if table_name not in SCHEMAS:
    raise ValueError(f"No schema defined for table '{table_name}'")

df = (
    spark.read
    .option("header", "true")
    .option("enforceSchema", "false")   # check header names against the schema
    .option("mode", "FAILFAST")         # a value that won't cast aborts the job
    .option("dateFormat", "yyyy-MM-dd")
    .option("timestampFormat", "yyyy-MM-dd'T'HH:mm:ssX")
    .schema(SCHEMAS[table_name])
    .csv(source_path)
)

if table_name == "observations":
    # Numeric copy only where Synthea says the value IS numeric; text values
    # (e.g. smoking status) keep VALUE and get NULL here instead of being lost.
    df = df.withColumn(
        "VALUE_NUM",
        F.when(F.col("TYPE") == "numeric", F.col("VALUE").cast("double")),
    )

df.repartition(1).write.mode("overwrite").parquet(output_path)

job.commit()
