SELECT
    "START" as start_date,
    "STOP" as stop_date,
    patient as patient_id,
    encounter as encounter_id,
    system as code_system,
    code as condition_code,
    description,
    description LIKE '%(disorder)' as is_disorder
  FROM {{ source('raw', 'conditions') }}  
