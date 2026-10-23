-- =============================================================================
-- CarePulse — 05_profile_conditions.sql
-- -----------------------------------------------------------------------------
-- Profiling RAW.CONDITIONS before building core.conditions and the
-- "active chronic conditions at discharge" feature (Session 14).
--
-- Read-only. Results recorded in comments are from Oct 16, 2026.
-- START / STOP are reserved words in Snowflake — always double-quote them.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Size and coverage
-- -----------------------------------------------------------------------------
-- Result: 57,537 distinct patients (= every patient in core.patients)
--         2,093,392 rows  → ~36 condition records per patient
-- Matching counts don't prove the same patients: core.conditions will get a
-- relationships test to core.patients.
SELECT COUNT(DISTINCT patient) AS distinct_patients,
       COUNT(*)                AS total_rows
FROM carepulse_db.raw.conditions;


-- -----------------------------------------------------------------------------
-- 2. Columns
-- -----------------------------------------------------------------------------
-- Result: START DATE, STOP DATE, PATIENT, ENCOUNTER, SYSTEM, CODE, DESCRIPTION
--   * No ID column → no natural primary key; need a composite key
--     (e.g. patient + encounter + code + start) — verify it is unique first.
--   * START / STOP are DATE, not TIMESTAMP → compare with discharged_at::DATE.
--   * ENCOUNTER = the visit where the condition was recorded.
--   * All columns nullable — RAW enforces nothing; CORE tests will.
DESC TABLE carepulse_db.raw.conditions;


-- -----------------------------------------------------------------------------
-- 3. Open conditions (no end date)
-- -----------------------------------------------------------------------------
-- Result: 536,112 of 2,093,392 rows = 25.6% have no STOP
SELECT COUNT(*) AS open_rows
FROM carepulse_db.raw.conditions
WHERE "STOP" IS NULL;


-- -----------------------------------------------------------------------------
-- 4. Most common descriptions
-- -----------------------------------------------------------------------------
-- Result: most of the top 15 are NOT diseases. The SNOMED semantic tag in
-- brackets says what each record is:
--   (situation) e.g. Medication review due — 414,104 rows, the #1 entry
--   (finding)   e.g. Stress, Full-time employment, Social isolation
--               (social determinants of health)
--   (disorder)  e.g. Gingivitis, Viral sinusitis, Acute bronchitis
-- → Counting all condition rows would be a bad feature; filter to (disorder).
SELECT description,
       COUNT(*) AS n_rows
FROM carepulse_db.raw.conditions
GROUP BY description
ORDER BY n_rows DESC
LIMIT 15;

-- 4.1 What the (situation) records are
SELECT DISTINCT description
FROM carepulse_db.raw.conditions
WHERE description LIKE '%(situation)%';


-- -----------------------------------------------------------------------------
-- 5. Hypothesis: chronic disorders stay open, acute ones get a STOP
-- -----------------------------------------------------------------------------
-- Result (top 25 disorders by rows) — the split is clean:
--   Chronic, ~93–100% open: Essential hypertension 100, Ischemic heart
--     disease 100, Metabolic syndrome X 100, Hyperlipidemia 100, Disorder of
--     kidney due to diabetes 100, Microalbuminuria (T2DM) 100,
--     Chronic sinusitis 97.7, Anemia 93.3
--   Acute, ~0–4% open: Gingivitis 0.6, Viral sinusitis 0.5, Acute viral
--     pharyngitis 0.3, Acute bronchitis 0.5, Fracture 2.5, Sprain 0.8,
--     COVID-19 3.2
--   Notes:
--     * CKD stage 1 = 78.5%: chronic, but its row STOPs when it progresses to
--       stage 2 — STOP can mean "replaced by something worse", not "cured".
--     * Small % open in acute conditions: patient history ends (death / end of
--       simulation) before they resolve — right-censoring.
--     * Loss of teeth = 100% open: long-lasting is not the same as medically
--       relevant to readmission.
--   LEAKAGE: STOP IS NULL describes the condition as of TODAY (end of data),
--   not at discharge. A condition active at a 2018 discharge that stopped in
--   2020 has STOP = 2020 and would be wrongly excluded. The feature must use a
--   point-in-time rule on START / STOP vs the discharge date.
-- Note: reusing the aliases open_rows / total_rows inside the same SELECT is a
-- Snowflake convenience; portable SQL repeats the expressions or uses a CTE.
SELECT description,
       COUNT(*)                                        AS total_rows,
       COUNT_IF("STOP" IS NULL)                        AS open_rows,
       ROUND(COUNT_IF("STOP" IS NULL) * 100 / COUNT(*), 1) AS pct_open
FROM carepulse_db.raw.conditions
WHERE description LIKE '%(disorder)'
GROUP BY description
ORDER BY total_rows DESC
LIMIT 25;
