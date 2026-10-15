WITH episode AS (
    SELECT
      episode_id,
        patient_id,
        admitted_at,
        discharged_at,
        stay_in_episode,
        readmitted_30d,
        episode_number
      FROM {{ ref('inpatient_episodes') }}
      WHERE is_eligible_index = TRUE
),
with_features AS(
    SELECT
        e.episode_id,
        e.patient_id,
        e.admitted_at,
        e.discharged_at,
        e.stay_in_episode,
        e.readmitted_30d,
        p.gender,
        DATEDIFF(year, p.birth_date, e.admitted_at::DATE) 
        - IFF(TO_VARCHAR(e.admitted_at::DATE, 'MM-DD') < TO_VARCHAR(p.birth_date, 'MM-DD'), 1, 0) AS age_at_admission,
        DATEDIFF(day, e.admitted_at::DATE, e.discharged_at::DATE) AS length_of_stay_days,
        e.episode_number - 1 AS prior_episodes
    FROM {{ ref('patients') }} p
    INNER JOIN episode e
    ON e.patient_id = p.patient_id
)
SELECT * FROM with_features
