SELECT episode_id,
         age_at_admission,
         length_of_stay_days,
         prior_episodes
FROM {{ ref('episode_features') }} f
WHERE (AGE_AT_ADMISSION < 0
OR AGE_AT_ADMISSION > 120)
OR LENGTH_OF_STAY_DAYS < 0
OR PRIOR_EPISODES < 0
