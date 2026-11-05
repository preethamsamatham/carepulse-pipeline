SELECT
    "START" as start_ts,
    "STOP" as stop_ts,
    patient as patient_id,
    encounter as encounter_id,
    system as code_system,
    code as procedure_code,
    description,
    base_cost,
    reasoncode as reason_code,
    reasondescription as reason_description,
    description ILIKE '%chemotherapy%' as is_chemotherapy
  FROM {{ source('raw', 'procedures') }}  