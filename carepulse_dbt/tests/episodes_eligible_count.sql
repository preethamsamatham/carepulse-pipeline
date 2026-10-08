SELECT 
count(*)
FROM {{ ref('inpatient_episodes') }}
WHERE is_eligible_index = TRUE
HAVING count(*) <> 51925 