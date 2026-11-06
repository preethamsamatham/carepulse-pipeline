SELECT COUNT(*) AS row_count
FROM {{ ref('episode_features') }}
HAVING row_count <> 51925