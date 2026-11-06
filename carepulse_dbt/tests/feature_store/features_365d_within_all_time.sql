SELECT * 
FROM {{ ref('episode_features') }} f
WHERE prior_episodes_365d > prior_episodes