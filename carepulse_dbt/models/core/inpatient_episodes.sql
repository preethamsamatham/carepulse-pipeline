WITH stay AS (
    SELECT 
         PATIENT_ID,
         ENCOUNTER_ID,
         START_TS as ADMITTED_AT,
         STOP_TS as DISCHARGED_AT
    FROM {{ ref('encounters') }}
    WHERE encounter_class = 'inpatient'
),
FLAGGED AS (
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
)
 SELECT * FROM episodes 