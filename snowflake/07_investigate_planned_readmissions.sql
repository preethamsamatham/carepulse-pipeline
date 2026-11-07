-- =============================================================================
-- CarePulse — 07_investigate_planned_readmissions.sql
-- -----------------------------------------------------------------------------
-- How we found that 92% of 30-day "readmissions" were scheduled chemotherapy,
-- proved it, and checked the new planned / unplanned labels (Sessions 18–19).
--
--   1. Profile the admission reason (encounters.reason_description)
--   2. Step A — self-join each readmitted episode to the next one: the gaps
--   3. Step B — why did they come back? (reason of the next stay)
--   4. Proof  — procedures performed in those readmission stays
--   5. core.procedures — the is_chemotherapy flag
--   6. The new labels in CORE and FEATURE_STORE
--
-- Read-only. Results recorded in comments are from Oct 30 – Nov 6, 2026.
-- Queries already saved in 06_validate_core_conditions.sql are not repeated.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE carepulse_wh;


-- =============================================================================
-- 1. The admission reason
-- =============================================================================

-- 1.1 Is "episode → the encounter that starts it" exactly one-to-one?
--     DISTINCT episodes = all episodes that found a match (none lost);
--     COUNT(*)          = matched rows (equal → no episode matched twice).
--     Result: 51,925 / 51,925 ✓ · 40 distinct reasons · 5 NULL reasons
SELECT COUNT(DISTINCT f.episode_id)         AS distinct_episodes,
       COUNT(*)                             AS matched_rows,
       COUNT(DISTINCT en.reason_description) AS distinct_reasons,
       COUNT_IF(en.reason_description IS NULL) AS null_reasons
FROM carepulse_db.feature_store.episode_features f
JOIN carepulse_db.core.encounters en
  ON  en.patient_id      = f.patient_id
  AND en.start_ts        = f.admitted_at
  AND en.encounter_class = 'inpatient';

-- 1.2 The 5 episodes with no recorded reason (inspect, don't SELECT *).
SELECT f.episode_id,
       f.admitted_at,
       en.description,
       en.reason_description
FROM carepulse_db.feature_store.episode_features f
JOIN carepulse_db.core.encounters en
  ON  en.patient_id      = f.patient_id
  AND en.start_ts        = f.admitted_at
  AND en.encounter_class = 'inpatient'
WHERE en.reason_description IS NULL;

-- 1.3 Readmission rate by admission reason (old label).
--     After GROUP BY, SELECT may only hold the group column + aggregates.
--     Result (top rows):
--       Non-small cell lung cancer        16,106 episodes  4,918 readm  30.5%
--       Dependent drug abuse               7,014              39        0.6%
--       Sterilization requested            6,115               4        0.1%
--       Small cell lung cancer             3,192           2,805       87.9%
--       Sleep disorder                     2,692               7        0.3%
--       Appendicitis                       2,565               3        0.1%
--       Chronic congestive heart failure   2,019             129        6.4%
--     Top 6 reasons = 37,684 episodes (72.6%); 9 reasons under 50 episodes.
--     The two lung cancer rows = 7,723 of 8,444 readmissions = 91.5%  ← odd
SELECT en.reason_description,
       COUNT(*)                                              AS episodes,
       COUNT_IF(f.readmitted_30d)                            AS readmitted,
       ROUND(COUNT_IF(f.readmitted_30d) * 100 / COUNT(*), 1) AS rate_pct
FROM carepulse_db.feature_store.episode_features f
JOIN carepulse_db.core.encounters en
  ON  en.patient_id      = f.patient_id
  AND en.start_ts        = f.admitted_at
  AND en.encounter_class = 'inpatient'
GROUP BY en.reason_description
ORDER BY episodes DESC;


-- =============================================================================
-- 2. Step A — self-join to the next episode: how long until they came back?
-- e1 = the index episode, e2 = the same patient's next episode.
-- =============================================================================

-- 2.1 Result: 8,444 pairs ✓ (one next stay per readmission); gap 1–30 days,
--     avg 26.1. Distribution of days_to_next_admission:
--       1–20 days   638  ( 8%)
--      21–27 days 2,743  (32%)
--      28–30 days 5,083  (60%)   ← piles up at the end of the window
--     Unplanned returns would spread out and lean early → this is a SCHEDULE.
--     (days_to_next_admission already exists in CORE — no need to recompute.)
SELECT COUNT(*)                               AS pairs,
       MIN(e1.days_to_next_admission)         AS min_gap_days,
       ROUND(AVG(e1.days_to_next_admission), 1) AS avg_gap_days,
       MAX(e1.days_to_next_admission)         AS max_gap_days
FROM carepulse_db.core.inpatient_episodes e1
JOIN carepulse_db.core.inpatient_episodes e2
  ON  e2.patient_id     = e1.patient_id
  AND e2.episode_number = e1.episode_number + 1
WHERE e1.is_eligible_index
  AND e1.readmitted_30d;

-- 2.2 The gap distribution itself.
SELECT e1.days_to_next_admission AS gap_days,
       COUNT(*)                  AS readmissions
FROM carepulse_db.core.inpatient_episodes e1
WHERE e1.is_eligible_index
  AND e1.readmitted_30d
GROUP BY gap_days
ORDER BY gap_days;


-- =============================================================================
-- 3. Step B — why did they come back?
-- Join encounters twice: en1 starts e1, en2 starts e2.
-- =============================================================================

-- Result (top rows):
--   Non-small cell lung cancer → same          4,842   avg gap 29.2
--   Small cell lung cancer     → same          2,797   avg gap 24.5
--   CABG history               → same            146           15.4
--   Chronic heart failure      → same            112           14.9
--   Aortic valve regurg./stenosis → History of valve replacement  96   ~2.5–2.9
-- 7,639 of 8,444 (90.5%) = lung cancer → the same cancer, on a regular cycle.
SELECT en1.reason_description                     AS first_reason,
       en2.reason_description                     AS next_reason,
       COUNT(*)                                   AS readmissions,
       ROUND(AVG(e1.days_to_next_admission), 1)   AS avg_gap_days
FROM carepulse_db.core.inpatient_episodes e1
JOIN carepulse_db.core.inpatient_episodes e2           -- the next stay
  ON  e2.patient_id     = e1.patient_id
  AND e2.episode_number = e1.episode_number + 1
JOIN carepulse_db.core.encounters en1                  -- why they came in
  ON  en1.patient_id      = e1.patient_id
  AND en1.start_ts        = e1.admitted_at
  AND en1.encounter_class = 'inpatient'
JOIN carepulse_db.core.encounters en2                  -- why they came back
  ON  en2.patient_id      = e2.patient_id
  AND en2.start_ts        = e2.admitted_at
  AND en2.encounter_class = 'inpatient'
WHERE e1.is_eligible_index
  AND e1.readmitted_30d
GROUP BY en1.reason_description, en2.reason_description
ORDER BY readmissions DESC
LIMIT 15;


-- =============================================================================
-- 4. Proof — what was DONE in the lung cancer readmission stays?
-- COUNT(DISTINCT stay): one stay has many procedures.
-- =============================================================================

-- Result:
--   Combined chemotherapy and radiation therapy   7,639  ← every single one
--   Hearing examination (chemo can affect hearing) 4,935
--   High-resolution CT of chest (tumour response)  3,430
-- → The readmissions are scheduled chemotherapy cycles: planned, not failures
--   of care. A label definition problem, not leakage.
SELECT p.description,
       COUNT(DISTINCT en2.encounter_id) AS stays_with_procedure
FROM carepulse_db.core.inpatient_episodes e1
JOIN carepulse_db.core.inpatient_episodes e2
  ON  e2.patient_id     = e1.patient_id
  AND e2.episode_number = e1.episode_number + 1
JOIN carepulse_db.core.encounters en1
  ON  en1.patient_id      = e1.patient_id
  AND en1.start_ts        = e1.admitted_at
  AND en1.encounter_class = 'inpatient'
JOIN carepulse_db.core.encounters en2
  ON  en2.patient_id      = e2.patient_id
  AND en2.start_ts        = e2.admitted_at
  AND en2.encounter_class = 'inpatient'
JOIN carepulse_db.raw.procedures p                     -- core.procedures came later
  ON  p.encounter = en2.encounter_id
WHERE e1.is_eligible_index
  AND e1.readmitted_30d
  AND en1.reason_description LIKE '%lung%'
GROUP BY p.description
ORDER BY stays_with_procedure DESC
LIMIT 15;


-- =============================================================================
-- 5. core.procedures — the is_chemotherapy flag (ILIKE '%chemotherapy%')
-- =============================================================================

-- 5.1 Which descriptions were flagged? Only real chemotherapy wanted.
--     Result: Combined chemotherapy and radiation therapy · Pre-operative
--     chemotherapy · Chemotherapy  ← capital C: plain LIKE would have missed it
SELECT DISTINCT description
FROM carepulse_db.core.procedures
WHERE is_chemotherapy;

-- 5.2 Flagged rows per description, flagged first.
--     Result: 118,538 / 2,432 / 121; all other 423 descriptions = 0
SELECT description,
       COUNT_IF(is_chemotherapy) AS chemo_rows
FROM carepulse_db.core.procedures
GROUP BY description
ORDER BY chemo_rows DESC;

-- 5.3 Three-valued check: TRUE + FALSE + NULL = 9,388,622.
--     Result: 121,091 / 9,267,531 / 0
SELECT COUNT_IF(is_chemotherapy)          AS true_rows,
       COUNT_IF(NOT is_chemotherapy)      AS false_rows,
       COUNT_IF(is_chemotherapy IS NULL)  AS null_rows
FROM carepulse_db.core.procedures;


-- =============================================================================
-- 6. The new labels
-- Planned = readmitted AND the NEXT stay contains chemotherapy (any encounter
-- inside its admission–discharge window). Unplanned = readmitted AND NOT.
-- =============================================================================

-- 6.1 CORE, eligible episodes only.
--     Result: 8,444 / 7,752 / 692 → 7,752 + 692 = 8,444 ✓
--     (Without the WHERE: 8,445 — one ineligible episode. Always filter.)
SELECT COUNT_IF(readmitted_30d)            AS readmitted,
       COUNT_IF(is_planned_readmission)    AS planned,
       COUNT_IF(unplanned_readmitted_30d)  AS unplanned
FROM carepulse_db.core.inpatient_episodes
WHERE is_eligible_index;

-- 6.2 FEATURE_STORE — already eligible-only, no filter needed.
--     Result: 51,925 / 8,444 (16.3%) / 692 (1.3%) ✓
SELECT COUNT(*)                            AS episodes,
       COUNT_IF(readmitted_30d)            AS readmitted,
       COUNT_IF(unplanned_readmitted_30d)  AS unplanned
FROM carepulse_db.feature_store.episode_features;
