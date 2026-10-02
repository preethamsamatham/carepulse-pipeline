SELECT 
id AS patient_id,
birthdate AS birth_date ,
deathdate AS death_date ,
gender,
race,
ethnicity,
marital AS marital_status,
state,
county,
fips,
NULLIF(zip3, '000') AS zip3,
IFF(zip3 = '000', FALSE, TRUE) AS geo_known,
healthcare_expenses,
healthcare_coverage,
income
FROM {{ source('raw', 'patients') }}

