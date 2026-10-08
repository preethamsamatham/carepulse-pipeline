SELECT 
encounter_id,
start_ts,
stop_ts,
length_of_stay_hours
FROM {{ ref('encounters') }}
WHERE length_of_stay_hours < 0