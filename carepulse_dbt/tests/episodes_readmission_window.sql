SELECT 
episode_id,
discharged_at,
next_admission_at, 
days_to_next_admission
FROM {{ ref('inpatient_episodes') }}
WHERE readmitted_30d = TRUE
AND days_to_next_admission NOT BETWEEN 1 AND 30