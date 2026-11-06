SELECT
episode_id, readmitted_30d, is_planned_readmission, unplanned_readmitted_30d
FROM {{ ref('inpatient_episodes') }}
where (readmitted_30d <> (is_planned_readmission OR unplanned_readmitted_30d)) OR (is_planned_readmission AND unplanned_readmitted_30d) 
