/* Active merchants per day (1 Oct – 30 Nov 2025) */

WITH base AS (
  SELECT
    (o.created_at + INTERVAL '6 hours')::date AS order_date,
    o.business_id
  FROM orders o
  WHERE
    (o.created_at + INTERVAL '6 hours')::date BETWEEN DATE '2025-10-01' AND DATE '2025-11-30'
    AND o.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
)

SELECT
  order_date,
  COUNT(DISTINCT business_id) AS active_merchants
FROM base
GROUP BY order_date
ORDER BY order_date;
