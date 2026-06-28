-- Merchants Signed Up (created_at) vs Merchant First Trips (first_order_date) - DoD
-- Replace :start_date and :end_date with your desired dates in TablePlus
-- Example: :start_date = '2026-01-01', :end_date = '2026-01-31'

WITH params AS (
  SELECT
    '2025-08-01'::date AS start_date,
    '2026-01-05'::date   AS end_date
),
days AS (
  SELECT generate_series(p.start_date, p.end_date, interval '1 day')::date AS dt
  FROM params p
),
signup AS (
  SELECT
    b.created_at::date AS dt,
    COUNT(*) AS merchants_signed_up
  FROM businesses b, params p
  WHERE b.created_at::date BETWEEN p.start_date AND p.end_date
    -- AND b.is_active = true          -- optional
  GROUP BY 1
),
first_trip AS (
  SELECT
    b.first_order_date::date AS dt,
    COUNT(*) AS merchant_first_trips
  FROM businesses b, params p
  WHERE b.first_order_date IS NOT NULL
    AND b.first_order_date::date BETWEEN p.start_date AND p.end_date
    -- AND b.is_active = true          -- optional
  GROUP BY 1
),
base AS (
  SELECT
    d.dt,
    COALESCE(s.merchants_signed_up, 0)   AS merchants_signed_up,
    COALESCE(f.merchant_first_trips, 0)  AS merchant_first_trips
  FROM days d
  LEFT JOIN signup s USING (dt)
  LEFT JOIN first_trip f USING (dt)
)
SELECT
  dt,
  merchants_signed_up,
  merchant_first_trips

FROM base
ORDER BY dt;
