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
),
with_history_365 AS (
    SELECT
        e.episode_id,
        COUNT(e2.episode_id) AS prior_episodes_365d
    FROM episode e
    LEFT JOIN {{ ref('inpatient_episodes') }} e2
    ON e.patient_id = e2.patient_id
    AND e2.admitted_at < e.admitted_at
    AND DATEDIFF(day, e2.admitted_at::DATE, e.admitted_at::DATE) <= 365
    GROUP BY e.episode_id
)
    SELECT         
        e.episode_id,
        e.patient_id,
        e.admitted_at,
        e.discharged_at,
        e.stay_in_episode,
        e.readmitted_30d,
        e.gender,
        e.age_at_admission,
        e.length_of_stay_days,
        e.prior_episodes,
        h.prior_episodes_365d
    FROM with_features e
    LEFT JOIN with_history_365 h
    ON e.episode_id = h.episode_id