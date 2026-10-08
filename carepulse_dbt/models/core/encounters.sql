SELECT 
id as encounter_id,
patient as patient_id,
"START" as start_ts,
"STOP" as stop_ts,
encounterclass as encounter_class,
organization as organization_id,
provider as provider_id,
payer as payer_id,
code,
description,
base_encounter_cost,
total_claim_cost,
payer_coverage,
reasoncode as reason_code,
reasondescription as reason_description,
DATEDIFF(minutes,"START", "STOP")/60 as length_of_stay_hours
FROM {{ source('raw', 'encounters') }}