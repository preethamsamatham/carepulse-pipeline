-- =============================================================================
-- CarePulse — 06_validate_core_conditions.sql
-- -----------------------------------------------------------------------------
-- Checks for core.conditions (is_disorder flag) and for the feature
-- feature_store.episode_features.active_disorders_at_discharge, plus the
-- investigation of the 0% readmission group (Sessions 15–17).
--
-- Read-only. Results recorded in comments are from Oct 27–29, 2026.
-- Full three-part names everywhere so the file runs in any worksheet context.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE carepulse_wh;      -- not the trial's default COMPUTE_WH


-- =============================================================================
-- 1. core.conditions — the is_disorder flag
-- =============================================================================

-- 1.1 Flag count in CORE.            Result: 676,052 (32.3% of 2,093,392)
SELECT COUNT_IF(is_disorder) AS disorder_rows
FROM carepulse_db.core.conditions;

-- 1.2 Independent recount from RAW (the model cannot have touched RAW).
--     Must equal 1.1.                Result: 676,052 ✓
SELECT COUNT(*) AS disorder_rows_raw
FROM carepulse_db.raw.conditions
WHERE description LIKE '%(disorder)';

-- 1.3 A boolean has three values: TRUE + FALSE + NULL = total.
--     Checking TRUE alone cannot see NULLs.
--     Result: 0 NULLs → FALSE = 1,417,340
SELECT COUNT(*) AS null_flags
FROM carepulse_db.core.conditions
WHERE is_disorder IS NULL;


-- =============================================================================
-- 2. feature_store.episode_features — active_disorders_at_discharge
-- =============================================================================

-- 2.1 NULLs. The final SELECT LEFT JOINs the counts back, so a missing episode
--     would show up as NULL.         Result: 0 rows ✓
SELECT episode_id
FROM carepulse_db.feature_store.episode_features
WHERE active_disorders_at_discharge IS NULL;

-- 2.2 Range. A fan-out join would give hundreds.   Result: 0 / 30 ✓
SELECT MIN(active_disorders_at_discharge) AS min_active,
       MAX(active_disorders_at_discharge) AS max_active
FROM carepulse_db.feature_store.episode_features;

-- 2.3 Distribution — one row per value, used to choose the buckets.
--     Result: sums to 51,925 ✓; peak at 4 (6,337); 8.3% have 0;
--             90% have ≤ 12; under 1% have 20+
SELECT active_disorders_at_discharge,
       COUNT(*) AS episodes
FROM carepulse_db.feature_store.episode_features
GROUP BY active_disorders_at_discharge
ORDER BY active_disorders_at_discharge;

-- 2.4 Signal check — readmission rate by bucket.
--     Labels are text and sort like a dictionary ('10-14' before '3-5'),
--     so order by the smallest value in each bucket.
--     The alias must not be a real column name, or GROUP BY uses the column.
--     Result:  0     →  4,335 /     0 /  0.0
--              1-2   →  7,639 /   228 /  3.0
--              3-5   → 17,562 / 3,258 / 18.6
--              6-9   → 12,431 / 2,709 / 21.8
--              10-14 →  6,964 / 1,610 / 23.1
--              15+   →  2,994 /   639 / 21.3
--              totals 51,925 / 8,444 ✓
--     Strong signal 0–2 vs 3+, then a plateau around 19–23%.
SELECT CASE
           WHEN active_disorders_at_discharge = 0              THEN '0'
           WHEN active_disorders_at_discharge BETWEEN 1  AND 2  THEN '1-2'
           WHEN active_disorders_at_discharge BETWEEN 3  AND 5  THEN '3-5'
           WHEN active_disorders_at_discharge BETWEEN 6  AND 9  THEN '6-9'
           WHEN active_disorders_at_discharge BETWEEN 10 AND 14 THEN '10-14'
           ELSE '15+'
       END                                                  AS bucket,
       COUNT(*)                                             AS episodes,
       COUNT_IF(readmitted_30d)                             AS readmitted,
       ROUND(COUNT_IF(readmitted_30d) * 100 / COUNT(*), 1)  AS rate_pct
FROM carepulse_db.feature_store.episode_features
GROUP BY bucket
ORDER BY MIN(active_disorders_at_discharge);


-- =============================================================================
-- 3. Investigation — why does the 0-disorder bucket have 0 readmissions?
-- An exact 0% (or 100%) is a question, not an answer.
-- =============================================================================

-- 3.1 Who is in the group?
--     Result: F → 3,429 episodes, avg age 27.7, avg stay 1.5 days
--             M →   906 episodes, avg age 16.6, avg stay 3.2 days
--     First guess (childbirth for the women) turned out to be WRONG — see 3.2.
SELECT gender,
       COUNT(*)                  AS episodes,
       AVG(age_at_admission)     AS avg_age,
       AVG(length_of_stay_days)  AS avg_stay_days
FROM carepulse_db.feature_store.episode_features
WHERE active_disorders_at_discharge = 0
GROUP BY gender;

-- 3.2 What were the stays for? Link each episode to the inpatient encounter
--     that starts it. description alone is generic ("Encounter for problem");
--     reason_description has the specific reason.
--     Result (counts sum to exactly 4,335 — every episode matched one encounter):
--       F  Admission to surgical department  / Sterilization requested   2,704
--       M  Encounter for problem             / Appendicitis                846
--       F  Encounter for problem             / Appendicitis                684
--       M+F Hospital admission for isolation / COVID-19                     32
--       M+F Non-urgent orthopedic admission  / ACL, patellar, MCL injuries ~50
--     → elective or one-off procedures: no reason to come back.
SELECT f.gender,
       en.description,
       en.reason_description,
       COUNT(DISTINCT f.episode_id) AS episodes
FROM carepulse_db.feature_store.episode_features f
JOIN carepulse_db.core.encounters en
  ON  en.patient_id      = f.patient_id
  AND en.start_ts        = f.admitted_at
  AND en.encounter_class = 'inpatient'
WHERE f.active_disorders_at_discharge = 0
GROUP BY f.gender, en.description, en.reason_description
ORDER BY episodes DESC
LIMIT 10;

-- 3.3 Appendicitis IS a disorder — so why 0? Pick one real case.
--     Result: patient 6112f7a1-…, admitted 1967-09-06, discharged 1967-09-10
SELECT f.episode_id,
       f.patient_id,
       f.admitted_at,
       f.discharged_at
FROM carepulse_db.feature_store.episode_features f
JOIN carepulse_db.core.encounters en
  ON  en.patient_id      = f.patient_id
  AND en.start_ts        = f.admitted_at
  AND en.encounter_class = 'inpatient'
WHERE f.active_disorders_at_discharge = 0
  AND en.reason_description LIKE '%Appendicitis%'
LIMIT 1;

-- 3.4 That patient's condition records around the stay.
--     Result: NO "Appendicitis" row exists. The 1967 stay left only
--       1967-09-06 | (no stop) | History of appendectomy (situation) | FALSE
--     and every disorder starts in 1990 or later → 0 active at discharge is
--     correct. Second guess ("stop date before discharge") was also wrong.
--     Synthea records acute surgical reasons on the ENCOUNTER, not in
--     conditions → idea: an admission_reason feature from reason_description.
SELECT start_date,
       stop_date,
       description,
       is_disorder
FROM carepulse_db.core.conditions
WHERE patient_id = '6112f7a1-0915-ef56-cf1e-c72d464a24f5'
  AND (description ILIKE '%append%' OR start_date BETWEEN '1967-01-01' AND '1968-12-31')
ORDER BY start_date;
