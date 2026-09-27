-- =============================================================================
-- CarePulse — Load curated Parquet into Snowflake RAW (Phase 3)
-- File: snowflake/02_load_raw.sql
--
-- Pattern per table (same three steps for all six):
--   1. INFER_SCHEMA            -> look at the columns/types Glue stored in the Parquet
--   2. CREATE TABLE ... USING TEMPLATE -> build the table from that schema (no hand typing)
--   3. COPY INTO ... MATCH_BY_COLUMN_NAME -> load, matching columns by name, not position
-- then verify the data itself against numbers already measured upstream.
--
-- Prerequisite: 01_setup.sql (warehouse, database, stage curated_stage, parquet_format)
--
-- Why INFER_SCHEMA is safe here (vs "never infer" for CSV in Session 5):
-- Parquet stores the types Glue wrote, so Snowflake READS the schema — it isn't guessing.
--
-- Re-running: CREATE uses IF NOT EXISTS. COPY INTO keeps a 64-day load history per
-- file, so a second run loads 0 rows (no duplicates). To reload a table on purpose:
--   TRUNCATE TABLE <t>;  then COPY INTO ... FORCE = TRUE
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE carepulse_wh;      -- not the trial's default COMPUTE_WH
USE SCHEMA carepulse_db.raw;     -- makes @curated_stage and 'parquet_format' resolve


-- =============================================================================
-- TABLE 1 — PATIENTS                                    STATUS: loaded + verified
-- =============================================================================

-- 1. Inspect. Result: 14 columns — dates as DATE, money as NUMBER(14,2),
--    INCOME as NUMBER(38,0) (Snowflake's single integer type), ZIP3/FIPS as TEXT.
--    "Id" is mixed case -> IGNORE_CASE below.
SELECT COLUMN_NAME, TYPE, NULLABLE, ORDER_ID
FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@curated_stage/patients/',
    FILE_FORMAT => 'parquet_format'
))
ORDER BY ORDER_ID;

-- 2. Create from the inferred schema.
--    OBJECT_CONSTRUCT(*) turns each schema row into an object; ARRAY_AGG ... ORDER BY
--    ORDER_ID keeps column order; USING TEMPLATE builds one column per object.
--    IGNORE_CASE => TRUE makes "Id" plain ID (no quotes needed in every query).
CREATE TABLE IF NOT EXISTS patients
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION    => '@curated_stage/patients/',
      FILE_FORMAT => 'parquet_format',
      IGNORE_CASE => TRUE
    ))
  );

-- Expect 14 columns, first one ID. VARCHAR(16777216) = TEXT; only actual
-- characters are stored, so the max length costs nothing.
DESC TABLE patients;

-- 3. Load. ON_ERROR defaults to ABORT_STATEMENT (fail fast, like Glue FAILFAST).
--    Result: LOADED, 57,537 parsed = 57,537 loaded, 0 errors.
COPY INTO patients
  FROM @curated_stage/patients/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Verify content, not just the load message. Every value was measured earlier in
-- the Parquet file. Result: 57537 | 57537 | 1915-10-14 | 2026-09-08 | 14618  (all match)
SELECT COUNT(*)               AS rows_loaded,
       COUNT(DISTINCT id)     AS distinct_ids,
       MIN(birthdate)         AS oldest,
       MAX(birthdate)         AS youngest,
       COUNT_IF(zip3 = '000') AS unknown_geo
FROM patients;


-- =============================================================================
-- TABLE 2 — ENCOUNTERS                    STATUS: loaded; timestamp check pending
-- First table with timestamps (Spark wrote them as legacy INT96).
-- =============================================================================

SELECT COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@curated_stage/encounters/',
    FILE_FORMAT => 'parquet_format'
))
ORDER BY ORDER_ID;

CREATE TABLE IF NOT EXISTS encounters
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION    => '@curated_stage/encounters/',
      FILE_FORMAT => 'parquet_format',
      IGNORE_CASE => TRUE
    ))
  );

-- Result: LOADED, 3,377,145 parsed = 3,377,145 loaded, 0 errors (baseline row count)
COPY INTO encounters
  FROM @curated_stage/encounters/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Verify INT96 came through as timestamps: START/STOP should be TIMESTAMP_NTZ
DESC TABLE encounters;

-- Verify the exact time against a known raw-CSV value (catches silent timezone shifts):
-- expect 2026-03-24 15:27:18 -> 15:42:18, wellness, 347.38
SELECT id, start, stop, encounterclass, total_claim_cost
FROM encounters
WHERE id = 'e7e708a7-8a2d-7c8a-a641-6730955ab4e9';


-- =============================================================================
-- TABLES 3–6 — same pattern                                   STATUS: not yet run
-- For each: check COPY output rows_parsed = rows_loaded and record the count.
-- =============================================================================

-- ---- CONDITIONS (START/STOP are plain DATEs) --------------------------------
CREATE TABLE IF NOT EXISTS conditions
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@curated_stage/conditions/', FILE_FORMAT => 'parquet_format', IGNORE_CASE => TRUE))
  );
COPY INTO conditions
  FROM @curated_stage/conditions/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- ---- MEDICATIONS -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS medications
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@curated_stage/medications/', FILE_FORMAT => 'parquet_format', IGNORE_CASE => TRUE))
  );
COPY INTO medications
  FROM @curated_stage/medications/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- ---- PROCEDURES --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS procedures
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@curated_stage/procedures/', FILE_FORMAT => 'parquet_format', IGNORE_CASE => TRUE))
  );
COPY INTO procedures
  FROM @curated_stage/procedures/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- ---- OBSERVATIONS (43.5M rows — time this load on X-Small) -------------------
-- Expect 43,551,685 rows; VALUE stays TEXT, VALUE_NUM is DOUBLE (NULL for text rows)
CREATE TABLE IF NOT EXISTS observations
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*)) WITHIN GROUP (ORDER BY ORDER_ID)
    FROM TABLE(INFER_SCHEMA(
      LOCATION => '@curated_stage/observations/', FILE_FORMAT => 'parquet_format', IGNORE_CASE => TRUE))
  );
COPY INTO observations
  FROM @curated_stage/observations/
  FILE_FORMAT = (FORMAT_NAME = 'parquet_format')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;


-- =============================================================================
-- FINAL CHECK — row counts for all six RAW tables in one view
-- =============================================================================
SELECT table_name, row_count
FROM carepulse_db.information_schema.tables
WHERE table_schema = 'RAW'
ORDER BY table_name;
