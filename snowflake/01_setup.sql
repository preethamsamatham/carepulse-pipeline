-- =============================================================================
-- CarePulse — Snowflake setup (Phase 3: warehouse ingestion)
-- File: snowflake/01_setup.sql
--
-- Creates the warehouse, database, layer schemas, S3 storage integration,
-- Parquet file format and external stage over the Glue curated/ output.
--
-- Account : AWS us-east-1 (same region as s3://carepulse-raw-preetham-2026)
--           CURRENT_ACCOUNT() = OIC72962 (locator); UI shows HNC80452
-- Edition : Standard
--
-- Safe to re-run: every CREATE uses IF NOT EXISTS.
-- Run statement by statement and check each result before the next.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- STEP 0 — Confirm the account is in the right cloud/region
-- Expect: AWS_US_EAST_1. A different region means cross-region S3 transfer
-- fees and no Snowpipe/SQS later — recreate the account instead of building on it.
-- -----------------------------------------------------------------------------
SELECT CURRENT_REGION(), CURRENT_ACCOUNT(), CURRENT_VERSION();


-- -----------------------------------------------------------------------------
-- STEP 1 — Warehouse, database and layer schemas (as SYSADMIN)
-- SYSADMIN owns data objects by convention; ACCOUNTADMIN is kept for
-- account-level objects only (least privilege).
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;

-- X-Small = 1 credit/hour; suspends after 60s idle; no billing until first query
CREATE WAREHOUSE IF NOT EXISTS carepulse_wh
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS carepulse_db;

-- Layers: RAW (as loaded from S3) -> CORE (cleaned/joined)
--         -> FEATURE_STORE (model features) -> MART (reporting)
CREATE SCHEMA IF NOT EXISTS carepulse_db.raw;
CREATE SCHEMA IF NOT EXISTS carepulse_db.core;
CREATE SCHEMA IF NOT EXISTS carepulse_db.feature_store;
CREATE SCHEMA IF NOT EXISTS carepulse_db.mart;

-- Verify: expect RAW, CORE, FEATURE_STORE, MART (+ INFORMATION_SCHEMA, PUBLIC)
SHOW SCHEMAS IN DATABASE carepulse_db;
SHOW WAREHOUSES LIKE 'carepulse_wh';

-- History: these were first created as "carepluse_*" (typo) and renamed with
--   ALTER DATABASE  carepluse_db RENAME TO carepulse_db;
--   ALTER WAREHOUSE carepluse_wh RENAME TO carepulse_wh;
-- RENAME keeps all schemas/objects inside. Not needed on a fresh run.


-- -----------------------------------------------------------------------------
-- STEP 2 — Storage integration (as ACCOUNTADMIN — account-level object)
-- Cross-account access: Snowflake's own AWS IAM user assumes the role
-- carepulse-snowflake-role in account 391732005285 (defined in infra/main.tf).
-- No access keys anywhere.
--
-- STORAGE_ALLOWED_LOCATIONS limits it to curated/ — raw CSVs with PII in the
-- bucket root can't be staged. (The IAM policy enforces the same prefix: two locks.)
--
-- WARNING: never CREATE OR REPLACE this integration. Replacing it generates a
-- new STORAGE_AWS_EXTERNAL_ID, which no longer matches the IAM trust policy,
-- and every stage breaks with an sts:AssumeRole error.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS carepulse_s3_int
    TYPE                      = EXTERNAL_STAGE
    STORAGE_PROVIDER          = 'S3'
    ENABLED                   = TRUE
    STORAGE_AWS_ROLE_ARN      = 'arn:aws:iam::391732005285:role/carepulse-snowflake-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://carepulse-raw-preetham-2026/curated/');

-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this output
-- into the trust policy of aws_iam_role.snowflake_role in infra/main.tf,
-- then terraform plan / apply.
DESC INTEGRATION carepulse_s3_int;

-- Let SYSADMIN use the integration so day-to-day work doesn't need ACCOUNTADMIN
GRANT USAGE ON INTEGRATION carepulse_s3_int TO ROLE SYSADMIN;


-- -----------------------------------------------------------------------------
-- STEP 3 — Keep the trial's default warehouse from burning credits
-- Snowsight selects COMPUTE_WH by default; cap its idle time and pause it.
-- (SUSPEND errors harmlessly if it's already suspended.)
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE compute_wh SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE compute_wh SUSPEND;


-- -----------------------------------------------------------------------------
-- STEP 4 — File format and external stage (as SYSADMIN)
-- A stage stores no data: it's a saved pointer (S3 path + integration + format).
-- Parquet carries its own column types from the Glue job, so no CSV options needed.
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;
USE WAREHOUSE carepulse_wh;
USE SCHEMA carepulse_db.raw;

CREATE FILE FORMAT IF NOT EXISTS parquet_format
    TYPE = PARQUET;

CREATE STAGE IF NOT EXISTS curated_stage
    STORAGE_INTEGRATION = carepulse_s3_int
    URL                 = 's3://carepulse-raw-preetham-2026/curated/'
    FILE_FORMAT         = parquet_format;

-- Verify the whole chain (integration -> AssumeRole -> IAM policy -> S3):
-- expect 6 Parquet files, one per table folder. "Last modified" is S3's own
-- object timestamp, read live — nothing is copied until COPY INTO.
LIST @curated_stage;


-- -----------------------------------------------------------------------------
-- NEXT — 02_load_raw.sql: INFER_SCHEMA -> CREATE TABLE USING TEMPLATE -> COPY INTO
-- -----------------------------------------------------------------------------
