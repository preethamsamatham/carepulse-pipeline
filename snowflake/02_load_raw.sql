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
-- TABLE 2 — ENCOUNTERS                    STATUS: loaded + timestamps verified
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

-- Verify the exact time against a known raw-CSV value (catches silent timezone shifts).
-- START is a reserved word in Snowflake -> quote as "START"/"STOP" (uppercase, since
-- quoted names are case-sensitive). Unquoted: "syntax error ... unexpected ','".
-- Rename to start_ts/stop_ts in CORE.
-- Result: 2026-03-24 15:27:18.000 -> 15:42:18.000, wellness, 347.38 — identical to the
-- raw CSV (2026-03-24T15:27:18Z). Spark INT96 -> Snowflake timestamp with NO shift.
SELECT id, "START", "STOP", encounterclass, total_claim_cost
FROM encounters
WHERE id = 'e7e708a7-8a2d-7c8a-a641-6730955ab4e9';


-- =============================================================================
-- TABLES 3–6 — same pattern                            STATUS: loaded, 0 errors
-- For each: check COPY output rows_parsed = rows_loaded and record the count.
-- =============================================================================

-- ---- CONDITIONS (START/STOP are plain DATEs) — 2,093,392 rows, 6.2s ------------
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

-- ---- MEDICATIONS — 2,903,828 rows, 11.8s --------------------------------------
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

-- ---- PROCEDURES — 9,388,622 rows, 26.6s ---------------------------------------
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

-- ---- OBSERVATIONS — 43,551,685 rows, 117.5s on X-Small ----------------------------
-- One 423MB file = one loading thread (X-Small has 8). Glue's repartition(1) limits
-- COPY parallelism -> experiment: repartition(8) and re-measure (open item).
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


-- VALUE_NUM survived the move. Result: 26842167 | 16709518 | 0 | 0 (same as check_parquet.py)
SELECT COUNT_IF(type = 'numeric')                            AS numeric_rows,
       COUNT_IF(type = 'text')                               AS text_rows,
       COUNT_IF(type = 'numeric' AND value_num IS NULL)      AS numeric_missing_num,
       COUNT_IF(type <> 'numeric' AND value_num IS NOT NULL) AS text_with_num
FROM observations;


-- =============================================================================
-- FINAL CHECK — row counts for all six RAW tables in one view
-- Result (matches every COPY output): CONDITIONS 2,093,392 · ENCOUNTERS 3,377,145 ·
-- MEDICATIONS 2,903,828 · OBSERVATIONS 43,551,685 · PATIENTS 57,537 ·
-- PROCEDURES 9,388,622  -> 61,372,209 rows total, 0 load errors
-- =============================================================================
SELECT table_name, row_count
FROM carepulse_db.information_schema.tables
WHERE table_schema = 'RAW'
ORDER BY table_name;

-- Load times + which warehouse ran each COPY (read back from query history).
-- Result: patients 2.0s, encounters 16.6s (CAREPULSE_WH); conditions 6.2s,
-- medications 11.8s, procedures 26.6s, observations 117.5s (COMPUTE_WH — the
-- workspace tab's default; fixed by setting user defaults in 01_setup.sql STEP 7).
SELECT REGEXP_SUBSTR(query_text, 'COPY INTO (\\w+)', 1, 1, 'i', 1) AS table_name,
       ROUND(total_elapsed_time / 1000, 1)                         AS seconds,
       warehouse_name
FROM TABLE(carepulse_db.information_schema.query_history(result_limit => 200))
WHERE query_type = 'COPY'
  AND execution_status = 'SUCCESS'
ORDER BY start_time;