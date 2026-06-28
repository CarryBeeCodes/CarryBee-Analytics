WITH params AS (
    SELECT 
        DATE '2025-01-01' AS start_date,
        DATE '2025-01-05' AS end_date
),

calendar AS (
    SELECT generate_series(
        (SELECT start_date FROM params),
        (SELECT end_date FROM params),
        INTERVAL '1 day'
    )::date AS filter_date
),

/* 1️⃣ Engaged */
engaged AS (
    SELECT 
        c.filter_date,
        o.business_id
    FROM calendar c
    JOIN orders o
      ON o.created_at::date = c.filter_date
    GROUP BY c.filter_date, o.business_id
),

/* 2️⃣ Active */
active AS (
    SELECT 
        c.filter_date,
        o.business_id
    FROM calendar c
    JOIN orders o
      ON o.sorted_at::date = c.filter_date
    GROUP BY c.filter_date, o.business_id
),

/* 3️⃣ Activated in 7 Days */
activated_7d AS (
    SELECT 
        c.filter_date,
        o.business_id
    FROM calendar c
    JOIN orders o
      ON o.sorted_at::date BETWEEN c.filter_date - INTERVAL '6 days'
                               AND c.filter_date
    GROUP BY c.filter_date, o.business_id
    HAVING COUNT(DISTINCT o.sorted_at::date) = 7
),

/* 4️⃣ Retention (reactivated) */
retention AS (
    SELECT 
        a.filter_date,
        a.business_id
    FROM active a
    WHERE NOT EXISTS (
        SELECT 1
        FROM orders x
        WHERE x.business_id = a.business_id
          AND x.sorted_at::date BETWEEN a.filter_date - INTERVAL '30 days'
                                     AND a.filter_date - INTERVAL '1 day'
    )
),

/* 5️⃣ Churn */
churn AS (
    SELECT 
        c.filter_date,
        o.business_id
    FROM calendar c
    JOIN orders o ON TRUE
    GROUP BY c.filter_date, o.business_id
    HAVING MAX(o.sorted_at::date) < c.filter_date - INTERVAL '30 days'
)

SELECT
    c.filter_date                                   AS metric_date,
    COUNT(DISTINCT e.business_id)                   AS merchants_engaged,
    COUNT(DISTINCT a.business_id)                   AS merchants_active,
    COUNT(DISTINCT act7.business_id)                AS merchants_activated_7d,
    COUNT(DISTINCT r.business_id)                   AS merchant_retention,
    COUNT(DISTINCT ch.business_id)                  AS merchant_churn
FROM calendar c
LEFT JOIN engaged e      ON e.filter_date = c.filter_date
LEFT JOIN active a       ON a.filter_date = c.filter_date
LEFT JOIN activated_7d act7 ON act7.filter_date = c.filter_date
LEFT JOIN retention r    ON r.filter_date = c.filter_date
LEFT JOIN churn ch       ON ch.filter_date = c.filter_date
GROUP BY c.filter_date
ORDER BY c.filter_date;
