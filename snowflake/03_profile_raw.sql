-- =============================================================================
-- CarePulse — Profile RAW before designing CORE
-- File: snowflake/03_profile_raw.sql
--
-- Every design decision in 04_core.sql traces back to a result recorded here.
-- Label definition reached: 30-day all-cause readmission between inpatient
-- EPISODES (overlapping / same-day stays merged), excluding in-episode deaths
-- and discharges to hospice -> 51,925 index episodes, 16.0% readmitted.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE carepulse_wh;
USE SCHEMA carepulse_db.raw;


-- -----------------------------------------------------------------------------
-- 1. Which encounter types exist, and how long do they last?
-- DATEDIFF('hour') counts hour BOUNDARIES crossed, not elapsed time (15:27->15:42 = 0,
-- 15:50->16:05 = 1) — fine for a rough profile; CORE uses minutes / 60.0.
--
-- Result:
--   ambulatory 1,857,470 enc · 56,417 pts · 1.9 h     emergency 126,269 · 40,657 · 5.7 h
--   wellness     705,558     · 57,537     · 0.9 h     inpatient  56,302 · 19,904 · 113.6 h (~4.7 d)
--   outpatient   434,096     · 53,079     · 0.6 h     home       17,232 ·  1,003 · 0.3 h
--   urgentcare   155,123     · 21,834     · 0.6 h     snf         8,438 ·  7,707 · 473.6 h
--   virtual        8,368     ·  3,849     · 0.6 h     hospice     8,289 ·  6,838 · 515.9 h
-- Decisions: inpatient = index stays and readmissions. Emergency/SNF/others = features,
-- not readmissions. Wellness covers all 57,537 patients -> every patient has encounters.
-- -----------------------------------------------------------------------------
SELECT encounterclass,
       COUNT(*)                                          AS encounters,
       COUNT(DISTINCT patient)                           AS patients,
       ROUND(AVG(DATEDIFF('hour', "START", "STOP")), 1)  AS avg_hours
FROM encounters
GROUP BY encounterclass
ORDER BY encounters DESC;


-- -----------------------------------------------------------------------------
-- 2. Naive label: next inpatient admission within 30 days of discharge.
-- LEAD("START") OVER (PARTITION BY patient ORDER BY "START") = the same patient's
-- next admission; NULL for their last stay (never counted).
--
-- Result: 56,302 index stays · 11,815 readmitted · 21.0%  <- inflated, see step 3
-- -----------------------------------------------------------------------------
WITH inpatient AS (
    SELECT patient,
           "START" AS admitted_at,
           "STOP"  AS discharged_at,
           LEAD("START") OVER (PARTITION BY patient ORDER BY "START") AS next_admitted_at
    FROM encounters
    WHERE encounterclass = 'inpatient'
)
SELECT COUNT(*)                                                         AS index_stays,
       COUNT_IF(DATEDIFF('day', discharged_at, next_admitted_at) <= 30) AS readmitted_30d,
       ROUND(100 * readmitted_30d / index_stays, 1)                     AS readmit_rate_pct
FROM inpatient;


-- -----------------------------------------------------------------------------
-- 3. Gap distribution — "<= 30" also counted negative and 0-day gaps.
--
-- Result:
--   1: negative (overlap)        789   <- overlapping records, not readmissions
--   2: same day (transfer?)    2,581   <- one continuous stay split in two
--   3: 1-30 days (readmission) 8,445   <- real readmissions
--   4: over 30 days           24,583
-- 789 + 2,581 + 8,445 = 11,815 (matches step 2). 36,398 stays have a next stay;
-- 56,302 - 36,398 = 19,904 = patients with any inpatient stay (each one's last stay).
-- 3,370 of 11,815 (29%) naive "readmissions" were artifacts -> true rate 8,445/56,302 = 15.0%.
-- -----------------------------------------------------------------------------
WITH inpatient AS (
    SELECT patient,
           "STOP" AS discharged_at,
           LEAD("START") OVER (PARTITION BY patient ORDER BY "START") AS next_admitted_at
    FROM encounters
    WHERE encounterclass = 'inpatient'
),
gaps AS (
    SELECT DATEDIFF('day', discharged_at, next_admitted_at) AS gap_days
    FROM inpatient
    WHERE next_admitted_at IS NOT NULL
)
SELECT CASE WHEN gap_days < 0              THEN '1: negative (overlap)'
            WHEN gap_days = 0              THEN '2: same day (transfer?)'
            WHEN gap_days BETWEEN 1 AND 30 THEN '3: 1-30 days (readmission)'
            ELSE                                '4: over 30 days'
       END AS gap_bucket,
       COUNT(*) AS stays
FROM gaps
GROUP BY gap_bucket
ORDER BY gap_bucket;


-- -----------------------------------------------------------------------------
-- 4. Merge overlapping / same-day stays into EPISODES (gaps-and-islands), re-measure.
--   flagged      : running MAX of earlier discharges (a short stay nested in a long
--                  one can't break the chain the way plain LAG would)
--   numbered     : 1 = new episode (first stay, or gap >= 1 day), else 0
--   episodes     : running SUM of those flags = episode number per patient
--   episode_span : one row per episode, first admission -> last discharge
--
-- Result: 52,932 episodes · 8,445 readmitted · 16.0%
--   52,932 = 56,302 - 3,370 (every overlap/transfer merged into its predecessor)
--   8,445  = exactly bucket 3 (no real readmission lost)
-- -----------------------------------------------------------------------------
WITH inp AS (
    SELECT patient, "START" AS admitted_at, "STOP" AS discharged_at
    FROM encounters
    WHERE encounterclass = 'inpatient'
),
flagged AS (
    SELECT *,
           MAX(discharged_at) OVER (PARTITION BY patient ORDER BY admitted_at
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_discharge
    FROM inp
),
numbered AS (
    SELECT *,
           CASE WHEN prev_max_discharge IS NULL
                  OR DATEDIFF('day', prev_max_discharge, admitted_at) > 0
                THEN 1 ELSE 0 END AS new_episode
    FROM flagged
),
episodes AS (
    SELECT patient,
           SUM(new_episode) OVER (PARTITION BY patient ORDER BY admitted_at
                                  ROWS UNBOUNDED PRECEDING) AS episode_no,
           admitted_at, discharged_at
    FROM numbered
),
episode_span AS (
    SELECT patient, episode_no,
           MIN(admitted_at)   AS admitted_at,
           MAX(discharged_at) AS discharged_at
    FROM episodes
    GROUP BY patient, episode_no
),
with_next AS (
    SELECT *, LEAD(admitted_at) OVER (PARTITION BY patient ORDER BY admitted_at) AS next_admitted_at
    FROM episode_span
)
SELECT COUNT(*)                                                                    AS episodes,
       COUNT_IF(DATEDIFF('day', discharged_at, next_admitted_at) BETWEEN 1 AND 30) AS readmitted_30d,
       ROUND(100 * readmitted_30d / episodes, 1)                                   AS readmit_rate_pct
FROM with_next;


-- -----------------------------------------------------------------------------
-- 5. Exclusions: died during the episode, or discharged to hospice.
-- First join between RAW tables — episodes stayed at 52,932, so every inpatient
-- encounter's patient exists in PATIENTS (referential integrity holds).
--
-- Result: 52,932 episodes · 1,000 died · 7 to hospice · 51,925 eligible (no overlap)
-- The 1,000 split (query 6): 991 genuine in-episode deaths + 9 with deathdate BEFORE
-- admission (impossible — Synthea data-quality issue, flagged separately in CORE).
-- Hospice = 7 depends on the 1-day discharge->hospice window (documented assumption).
-- -----------------------------------------------------------------------------
WITH inp AS (
    SELECT patient, "START" AS admitted_at, "STOP" AS discharged_at
    FROM encounters
    WHERE encounterclass = 'inpatient'
),
flagged AS (
    SELECT *,
           MAX(discharged_at) OVER (PARTITION BY patient ORDER BY admitted_at
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_discharge
    FROM inp
),
numbered AS (
    SELECT *,
           CASE WHEN prev_max_discharge IS NULL
                  OR DATEDIFF('day', prev_max_discharge, admitted_at) > 0
                THEN 1 ELSE 0 END AS new_episode
    FROM flagged
),
episodes AS (
    SELECT patient,
           SUM(new_episode) OVER (PARTITION BY patient ORDER BY admitted_at
                                  ROWS UNBOUNDED PRECEDING) AS episode_no,
           admitted_at, discharged_at
    FROM numbered
),
episode_span AS (
    SELECT patient, episode_no,
           MIN(admitted_at)   AS admitted_at,
           MAX(discharged_at) AS discharged_at
    FROM episodes
    GROUP BY patient, episode_no
),
excl AS (
    SELECT e.*,
           p.deathdate,
           (p.deathdate IS NOT NULL
            AND p.deathdate <= DATEADD('day', 1, e.discharged_at)::DATE)      AS died_in_episode,
           EXISTS (SELECT 1 FROM encounters h
                   WHERE h.patient = e.patient
                     AND h.encounterclass = 'hospice'
                     AND h."START" BETWEEN e.discharged_at
                                       AND DATEADD('day', 1, e.discharged_at)) AS to_hospice
    FROM episode_span e
    JOIN patients p ON p.id = e.patient
)
SELECT COUNT(*)                                          AS episodes,
       COUNT_IF(died_in_episode)                         AS died_in_episode,
       COUNT_IF(to_hospice)                              AS discharged_to_hospice,
       COUNT_IF(NOT died_in_episode AND NOT to_hospice)  AS eligible_index_episodes
FROM excl;

-- 6. (same CTEs as 5) — split the 1,000 deaths by timing:
-- SELECT CASE WHEN deathdate <  admitted_at::DATE                      THEN '1: died BEFORE admission (data issue)'
--             WHEN deathdate <= DATEADD('day', 1, discharged_at)::DATE THEN '2: died during episode'
--        END AS when_died, COUNT(*) AS episodes
-- FROM excl WHERE died_in_episode GROUP BY when_died ORDER BY when_died;
-- Result: 1: 9 · 2: 991


-- -----------------------------------------------------------------------------
-- Label funnel (-> core.inpatient_episodes in 04_core.sql)
--   56,302 inpatient encounters
--   52,932 episodes after merging overlaps/transfers
--   -  991 died during episode
--   -    9 deathdate before admission (data issue)
--   -    7 discharged to hospice
--   51,925 eligible index episodes · 16.0% readmitted within 30 days
-- -----------------------------------------------------------------------------
