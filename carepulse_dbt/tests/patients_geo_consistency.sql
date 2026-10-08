SELECT patient_id, zip3, geo_known
FROM {{ ref('patients') }}
WHERE (zip3 IS NULL AND geo_known = TRUE)
OR (zip3 IS NOT NULL AND geo_known = FALSE)