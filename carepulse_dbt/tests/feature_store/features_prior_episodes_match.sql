SELECT
    f.episode_id,
    f.prior_episodes,
    COUNT(i.episode_id) AS earlier_episodes_counted
FROM {{ref('episode_features') }} f
LEFT JOIN {{ref('inpatient_episodes') }} i
       ON i.patient_id  = f.patient_id
      AND i.admitted_at < f.admitted_at
GROUP BY f.episode_id, f.prior_episodes
HAVING COUNT(i.episode_id) <> f.prior_episodes