WITH stay AS (
    SELECT 
         patient_id,
         encounter_id,
         START_TS as ADMITTED_AT,
         STOP_TS as DISCHARGED_AT
    FROM {{ ref('encounters') }}
    WHERE encounter_class = 'inpatient'
),
flagged AS (
    SELECT * ,
    MAX(discharged_at) OVER (PARTITION BY patient_id ORDER BY ADMITTED_AT
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_discharge
    FROM stay
) ,
numbered as(
    SELECT *,
    CASE WHEN prev_max_discharge IS NULL 
    OR DATEDIFF(day, prev_max_discharge, ADMITTED_AT) > 0 THEN 1
    ELSE 0 END AS new_episode
    from FLAGGED
),
episodes as (
    SELECT *,
    SUM(new_episode) OVER (PARTITION BY patient_id ORDER BY ADMITTED_AT
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS episode_number
    FROM numbered
),
episode_span AS (
    SELECT patient_id,
           episode_number,
           MIN(ADMITTED_AT) AS admitted_at,
           MAX(DISCHARGED_AT) AS discharged_at,
           COUNT(*) AS stay_in_episode
           FROM episodes
           GROUP BY patient_id, episode_number
           ),
 with_death AS (
    SELECT e.*,
    p.death_date,
    (p.death_date IS NOT NULL AND p.death_date < e.admitted_at ::DATE) AS death_before_admission,
    (p.death_date IS NOT NULL AND p.death_date >= e.admitted_at ::DATE AND p.death_date <= DATEADD(day, 1, e.discharged_at ::DATE)) AS died_in_episode
    FROM episode_span e
    JOIN {{ ref('patients') }} p
    ON e.patient_id = p.patient_id
 ),
 with_hospice AS (
    SELECT d.*,
    EXISTS (
        SELECT 1
        FROM {{ ref('encounters') }} h
        WHERE h.patient_id = d.patient_id
        AND h.encounter_class = 'hospice'
        AND h.start_ts BETWEEN d.discharged_at AND DATEADD(day, 1, d.discharged_at)
    ) AS discharged_to_hospice
    FROM with_death d
 ),
 with_next AS (
    SELECT *,
    LEAD(admitted_at) OVER (PARTITION BY patient_id ORDER BY admitted_at) 
     AS next_admission_at
    FROM with_hospice
 ),
 final AS (
    SELECT 
    patient_id || '-' || episode_number AS episode_id,
    patient_id,
    episode_number,
    admitted_at,
    discharged_at,
    stay_in_episode,
    death_date,
    died_in_episode,
    death_before_admission,
    discharged_to_hospice,
    (NOT died_in_episode AND NOT death_before_admission AND NOT discharged_to_hospice) AS is_eligible_index,
    next_admission_at,
    DATEDIFF('day', discharged_at, next_admission_at) AS days_to_next_admission,
    (next_admission_at IS NOT NULL AND DATEDIFF('day', discharged_at, next_admission_at) <= 30) AS readmitted_30d
    FROM with_next
 )
 SELECT * FROM final 