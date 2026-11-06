-- =============================================================================
-- CarePulse — 04_validate_core_and_features.sql
-- -----------------------------------------------------------------------------
-- Ad-hoc validation queries run in Snowflake worksheets while building the
-- dbt models (Sessions 9–13). Each check records the result it returned, so
-- re-running this file is a quick regression check after any model change.
--
-- Layers covered:
--   1. CORE.patients
--   2. CORE.encounters
--   3. CORE.inpatient_episodes      (episodes, exclusions, 30-day label)
--   4. FEATURE_STORE.episode_features (age fix, ranges, leakage, signal)
--
-- Notes
--   * Read-only: SELECT / DESC / SHOW only. Tables are built by dbt
--     (`dbt build`), never by hand in a worksheet.
--   * Always use full three-part names (database.schema.table) here.
--     A bare name resolves against the worksheet's current schema and can
--     silently read the wrong table (e.g. RAW.PATIENTS instead of CORE).
--   * "Expected" values are the results at commit 8d408c5.
-- =============================================================================


-- =============================================================================
-- 1. CORE.patients
-- =============================================================================

-- 1.1 Row count, key uniqueness, and the zip3 / geo_known pair.
--     zip3 '000' (unknown area) is turned into NULL and geo_known = FALSE,
--     so geo_unknown and zip3_null must be equal.
--     Expected: total_rows 57,537 = distinct_patients; geo_unknown = zip3_null
SELECT COUNT(*)                     AS total_rows,
       COUNT(DISTINCT patient_id)   AS distinct_patients,
       COUNT_IF(geo_known = FALSE)  AS geo_unknown,
       COUNT_IF(zip3 IS NULL)       AS zip3_null
FROM carepulse_db.core.patients;

-- 1.2 What the CORE schema contains, and the patients column list
SHOW TABLES IN SCHEMA carepulse_db.core;
DESC TABLE carepulse_db.core.patients;


-- =============================================================================
-- 2. CORE.encounters
-- =============================================================================

-- 2.1 RAW vs CORE column names side by side (renames: ID → encounter_id,
--     "START"/"STOP" → start_ts/stop_ts, etc.)
DESC TABLE carepulse_db.raw.encounters;
DESC TABLE carepulse_db.core.encounters;

-- 2.2 Row count, key uniqueness, no negative stays
--     Expected: 3,377,145 rows = distinct encounters; neg_length 0
SELECT COUNT(*)                            AS total_rows,
       COUNT(DISTINCT encounter_id)        AS distinct_encounters,
       COUNT_IF(length_of_stay_hours < 0)  AS neg_length
FROM carepulse_db.core.encounters;

-- 2.3 Spot-check one encounter by hand: stop_ts − start_ts should match
--     length_of_stay_hours (this one: 0.25 h)
SELECT encounter_id, start_ts, stop_ts, length_of_stay_hours
FROM carepulse_db.core.encounters
WHERE encounter_id = 'e7e708a7-8a2d-7c8a-a641-6730955ab4e9';


-- =============================================================================
-- 3. CORE.inpatient_episodes
-- =============================================================================

DESC TABLE carepulse_db.core.inpatient_episodes;

-- 3.1 Shape: one row per episode, key is unique
--     Expected: 52,932 rows = 52,932 distinct episode_ids; 19,904 patients;
--               max 66 episodes for one patient
SELECT COUNT(*)                     AS total_rows,
       COUNT(DISTINCT episode_id)   AS distinct_episode_ids,
       COUNT(DISTINCT patient_id)   AS patients,
       MAX(episode_number)          AS most_episodes_one_patient
FROM carepulse_db.core.inpatient_episodes;

-- 3.2 Gaps-and-islands merge: how many raw stays became each episode
--     Expected: 52,932 episodes from 56,302 stays; 2,368 merged episodes;
--               at most 4 stays in one episode
SELECT COUNT(*)                        AS episodes,
       SUM(stay_in_episode)            AS total_stays,
       COUNT_IF(stay_in_episode > 1)   AS merged_episodes,
       MAX(stay_in_episode)            AS most_stays_in_one
FROM carepulse_db.core.inpatient_episodes;

-- 3.3 Death flags. The two flags must never both be TRUE.
--     Expected: died 991, data_issue 9, both_flags 0
--     (A boundary bug once gave 827 / 173 — same-day deaths fell into the
--      wrong flag. Fixed with < and >=.)
SELECT COUNT(*)                                              AS episodes,
       COUNT_IF(died_in_episode)                             AS died,
       COUNT_IF(death_before_admission)                      AS data_issue,
       COUNT_IF(died_in_episode AND death_before_admission)  AS both_flags
FROM carepulse_db.core.inpatient_episodes;

-- 3.4 Hospice exclusion and the eligibility funnel
--     52,932 − 991 died − 9 data issue − 7 hospice = 51,925 eligible
--     Expected: hospice 7; hospice_and_died 0; eligible 51,925
SELECT COUNT(*)                                          AS episodes,
       COUNT_IF(discharged_to_hospice)                   AS hospice,
       COUNT_IF(discharged_to_hospice AND died_in_episode) AS hospice_and_died,
       COUNT_IF(NOT died_in_episode
                AND NOT death_before_admission
                AND NOT discharged_to_hospice)           AS eligible
FROM carepulse_db.core.inpatient_episodes;

-- 3.5 The 30-day readmission label and the training-set rate
--     Expected: 52,932 / 52,932 / 8,445 / 51,925 / 8,444 / 16.3
--     (16.3% is over eligible episodes; 16.0% was over all episodes)
SELECT COUNT(*)                                          AS episodes,
       COUNT(DISTINCT episode_id)                        AS distinct_ids,
       COUNT_IF(readmitted_30d)                          AS readmitted_all,
       COUNT_IF(is_eligible_index)                       AS eligible,
       COUNT_IF(is_eligible_index AND readmitted_30d)    AS readmitted_eligible,
       ROUND(100 * COUNT_IF(is_eligible_index AND readmitted_30d)
                 / COUNT_IF(is_eligible_index), 1)       AS rate_pct
FROM carepulse_db.core.inpatient_episodes;

-- 3.6 Look at one patient's episodes in order (example patient with
--     2 episodes 38 years apart: 1958 and 1996)
SELECT *
FROM carepulse_db.core.inpatient_episodes
WHERE patient_id = '1144d47c-0d3e-f3f3-ec82-81fb61331139'
ORDER BY admitted_at;


-- =============================================================================
-- 4. FEATURE_STORE.episode_features
-- =============================================================================

DESC TABLE carepulse_db.feature_store.episode_features;

-- -----------------------------------------------------------------------------
-- 4.1 Age at admission — the DATEDIFF(year) boundary bug
-- -----------------------------------------------------------------------------
-- DATEDIFF(year, …) only subtracts the year numbers, so it ignores whether
-- the birthday has happened yet in the admission year.

-- 4.1a Show the bug: real ages are 29 and 30, DATEDIFF says 30 and 30
SELECT DATEDIFF(year, '1990-12-31'::DATE, '2020-01-01'::DATE) AS should_be_29;
SELECT DATEDIFF(year, '1990-01-01'::DATE, '2020-12-31'::DATE) AS should_be_30;

-- 4.1b The fix: subtract 1 when the admission's 'MM-DD' is before the birth
--      'MM-DD'. Zero-padded 'MM-DD' strings compare in date order.
--      Test the four boundary cases (expected 29, 30, 29, 30):
SELECT DATEDIFF(year, '1990-12-31'::DATE, '2020-01-01'::DATE)
       - IFF(TO_VARCHAR('2020-01-01'::DATE, 'MM-DD') < TO_VARCHAR('1990-12-31'::DATE, 'MM-DD'), 1, 0) AS age_29;
SELECT DATEDIFF(year, '1990-01-01'::DATE, '2020-12-31'::DATE)
       - IFF(TO_VARCHAR('2020-12-31'::DATE, 'MM-DD') < TO_VARCHAR('1990-01-01'::DATE, 'MM-DD'), 1, 0) AS age_30;
SELECT DATEDIFF(year, '1990-06-15'::DATE, '2020-06-14'::DATE)
       - IFF(TO_VARCHAR('2020-06-14'::DATE, 'MM-DD') < TO_VARCHAR('1990-06-15'::DATE, 'MM-DD'), 1, 0) AS day_before_birthday_29;
SELECT DATEDIFF(year, '1990-06-15'::DATE, '2020-06-15'::DATE)
       - IFF(TO_VARCHAR('2020-06-15'::DATE, 'MM-DD') < TO_VARCHAR('1990-06-15'::DATE, 'MM-DD'), 1, 0) AS on_birthday_30;

-- 4.1c How many rows the fix changed (= rows where the birthday had not
--      been reached). Expected: 1 → 24,261 · 0 → 27,664 (46.7% corrected)
--      Note: the alias must not match a real column name — GROUP BY prefers
--      the column (an alias named age_at_admission grouped by real age).
SELECT IFF(TO_VARCHAR(e.admitted_at::DATE, 'MM-DD') < TO_VARCHAR(p.birth_date, 'MM-DD'), 1, 0)
           AS birthday_not_reached,
       COUNT(*) AS episodes
FROM carepulse_db.feature_store.episode_features e
INNER JOIN carepulse_db.core.patients p
        ON p.patient_id = e.patient_id
GROUP BY birthday_not_reached;

-- -----------------------------------------------------------------------------
-- 4.2 Ranges
-- -----------------------------------------------------------------------------
-- Expected: age 0 / ≤110 · LOS 1 / 233 · prior 0 / 64 · prior_365d 0 / 13
SELECT MIN(age_at_admission)     AS min_age,      MAX(age_at_admission)     AS max_age,
       MIN(length_of_stay_days)  AS min_los,      MAX(length_of_stay_days)  AS max_los,
       MIN(prior_episodes)       AS min_prior,    MAX(prior_episodes)       AS max_prior,
       MIN(prior_episodes_365d)  AS min_prior365, MAX(prior_episodes_365d)  AS max_prior365
FROM carepulse_db.feature_store.episode_features;

-- 4.2a Why min LOS is 1, not 0: shortest eligible episode in hours.
--      Expected: 24 → no same-day inpatient episodes in this data
SELECT MIN(DATEDIFF(hour, admitted_at, discharged_at)) AS shortest_episode_hours
FROM carepulse_db.feature_store.episode_features;

-- -----------------------------------------------------------------------------
-- 4.3 Leakage checks on prior_episodes  (every query: expected 0 rows)
-- -----------------------------------------------------------------------------

-- 4.3a prior_episodes = 0 must mean "this is the patient's first episode"
SELECT episode_id, prior_episodes
FROM carepulse_db.feature_store.episode_features
WHERE prior_episodes = 0
  AND episode_id NOT LIKE '%-1';

-- 4.3b Recount prior episodes independently (join + count) and compare.
--      LEFT JOIN, not JOIN: an inner join drops every first episode (no
--      earlier match), so the check would silently skip 19,644 rows.
--      COUNT(i.episode_id), not COUNT(*): for a first episode the LEFT JOIN
--      gives one all-NULL row; COUNT(*) would count it as 1.
SELECT f.episode_id,
       f.prior_episodes,
       COUNT(i.episode_id) AS earlier_episodes_counted
FROM carepulse_db.feature_store.episode_features f
LEFT JOIN carepulse_db.core.inpatient_episodes i
       ON i.patient_id  = f.patient_id
      AND i.admitted_at < f.admitted_at
GROUP BY f.episode_id, f.prior_episodes
HAVING COUNT(i.episode_id) <> f.prior_episodes;

-- -----------------------------------------------------------------------------
-- 4.4 prior_episodes_365d checks  (expected 0 rows each)
-- -----------------------------------------------------------------------------

-- 4.4a The 365-day window can never hold more than all-time history
SELECT episode_id, prior_episodes, prior_episodes_365d
FROM carepulse_db.feature_store.episode_features
WHERE prior_episodes_365d > prior_episodes;

-- 4.4b No all-time history ⇒ no recent history
--      (already covered by 4.4a: 365d ≥ 1 with prior 0 means 365d > prior)
SELECT episode_id, prior_episodes, prior_episodes_365d
FROM carepulse_db.feature_store.episode_features
WHERE prior_episodes = 0
  AND prior_episodes_365d <> 0;

-- 4.4c NULLs: comparisons and MIN/MAX skip NULLs, so 4.2 and 4.4a/b
--      cannot see them. Check explicitly.
SELECT episode_id
FROM carepulse_db.feature_store.episode_features
WHERE prior_episodes_365d IS NULL;

-- -----------------------------------------------------------------------------
-- 4.5 Signal check — readmission rate by bucket of prior_episodes_365d
-- -----------------------------------------------------------------------------
-- Correctness checks prove the feature is right; this shows it is useful.
-- Buckets are for reading only — the model gets the raw count.
-- A bucket near 100% would be a leakage alarm.
-- Expected: 0 → 30,160 / 702 / 2.3 · 1 → 3,176 / 319 / 10.0
--           2 → 824 / 247 / 30.0   · 3+ → 17,765 / 7,176 / 40.4
--           totals 51,925 episodes / 8,444 readmitted
SELECT CASE WHEN prior_episodes_365d = 0 THEN '0'
            WHEN prior_episodes_365d = 1 THEN '1'
            WHEN prior_episodes_365d = 2 THEN '2'
            ELSE '3+'
       END                                                      AS bucket,
       COUNT(episode_id)                                        AS episodes,
       COUNT_IF(readmitted_30d)                                 AS readmitted,
       ROUND(COUNT_IF(readmitted_30d) * 100 / COUNT(episode_id), 1) AS rate_pct
       -- multiply before dividing: safe in databases with integer division
FROM carepulse_db.feature_store.episode_features
GROUP BY bucket
ORDER BY bucket;


-- =============================================================================
-- Appendix — development checks from building inpatient_episodes step by step
-- -----------------------------------------------------------------------------
-- These ran against intermediate versions of the model, while the CTE
-- outputs (prev_max_discharge, new_episode) were still in the final SELECT.
-- Those columns are not in the finished table, so the queries are kept
-- commented out as a record of how the gaps-and-islands logic was verified.
-- =============================================================================
/*
-- A.1 First stays: rows with no earlier discharge. Expected 19,904
SELECT COUNT(*)                              AS total_rows,
       COUNT_IF(prev_max_discharge IS NULL)  AS first_stays
FROM carepulse_db.core.inpatient_episodes;

-- A.2 Classify every stay by its gap to the latest earlier discharge
WITH labelled AS (
    SELECT *,
           DATEDIFF('day', prev_max_discharge, admitted_at) AS gap_days,
           CASE
               WHEN prev_max_discharge IS NULL                            THEN '1: first stay'
               WHEN DATEDIFF('day', prev_max_discharge, admitted_at) < 0  THEN '2: overlap (same episode)'
               WHEN DATEDIFF('day', prev_max_discharge, admitted_at) = 0  THEN '3: same-day transfer (same episode)'
               ELSE                                                            '4: new episode'
           END AS stay_type
    FROM carepulse_db.core.inpatient_episodes
)
SELECT stay_type, COUNT(*) AS stays
FROM labelled
GROUP BY stay_type
ORDER BY stay_type;

-- A.3 Find patients who have all three cases (overlap, same-day transfer,
--     new episode) — good examples to trace by hand
WITH labelled AS (
    SELECT patient_id,
           DATEDIFF('day', prev_max_discharge, admitted_at) AS gap_days
    FROM carepulse_db.core.inpatient_episodes
)
SELECT patient_id,
       COUNT(*)                AS stays,
       COUNT_IF(gap_days < 0)  AS overlaps,
       COUNT_IF(gap_days = 0)  AS same_day_transfers,
       COUNT_IF(gap_days > 0)  AS new_episodes
FROM labelled
GROUP BY patient_id
HAVING COUNT_IF(gap_days < 0) > 0
   AND COUNT_IF(gap_days = 0) > 0
   AND COUNT_IF(gap_days > 0) > 0
ORDER BY stays
LIMIT 10;

-- A.4 Trace one of those patients stay by stay
SELECT admitted_at, discharged_at, prev_max_discharge
FROM carepulse_db.core.inpatient_episodes
WHERE patient_id = 'f97542f5-6415-941b-7077-571bfa50da71'
ORDER BY admitted_at;

-- A.5 Number of episodes = sum of new-episode flags. Expected 52,932
SELECT COUNT(*)          AS total_rows,
       SUM(new_episode)  AS episodes
FROM carepulse_db.core.inpatient_episodes;
*/
