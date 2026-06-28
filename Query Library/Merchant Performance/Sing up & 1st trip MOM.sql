WITH params AS (
  SELECT
    '2025-08-01'::date AS start_date,
    '2026-01-05'::date AS end_date
),
months AS (
  SELECT generate_series(
           date_trunc('month', p.start_date)::date,
           date_trunc('month', p.end_date)::date,
           interval '1 month'
         )::date AS dt
  FROM params p
),
signup AS (
  SELECT
    date_trunc('month', b.created_at)::date AS dt,
    COUNT(*) AS merchants_signed_up
  FROM businesses b, params p
  WHERE b.created_at::date BETWEEN p.start_date AND p.end_date
  GROUP BY 1
),
first_trip AS (
  SELECT
    date_trunc('month', b.first_order_date)::date AS dt,
    COUNT(*) AS merchant_first_trips
  FROM businesses b, params p
  WHERE b.first_order_date IS NOT NULL
    AND b.first_order_date::date BETWEEN p.start_date AND p.end_date
  GROUP BY 1
)
SELECT
  m.dt,
  COALESCE(s.merchants_signed_up, 0)  AS merchants_signed_up,
  COALESCE(f.merchant_first_trips, 0) AS merchant_first_trips
FROM months m
LEFT JOIN signup s ON s.dt = m.dt
LEFT JOIN first_trip f ON f.dt = m.dt
ORDER BY m.dt;
