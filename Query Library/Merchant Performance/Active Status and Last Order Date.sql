/* Business activity (BD time = UTC+6)
   - last_order_date shown in BD local
   - active_status = Inactive if last_order_date < (now_local - 5 days) OR no orders
*/

WITH
params AS (
  SELECT
    /* Put your business IDs here */
    ARRAY[
      -- 6190,
      -- 7274
    ]::int[] AS business_ids,

    /* BD local "now" */
    ((now() AT TIME ZONE 'UTC') + INTERVAL '6 hours') AS local_now
),
biz AS (
  SELECT unnest(p.business_ids) AS business_id
  FROM params p
),
last_order AS (
  SELECT
    o.business_id,
    MAX(o.sorted_at + INTERVAL '6 hours') AS last_order_date
  FROM orders o
  JOIN params p ON TRUE
  WHERE o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
    AND o.business_id = ANY(p.business_ids)
  GROUP BY o.business_id
)
SELECT
  b.business_id,
  CASE
    WHEN lo.last_order_date IS NULL
      OR lo.last_order_date < (p.local_now - INTERVAL '5 days')
      THEN 'Inactive'
    ELSE 'Active'
  END AS active_status,
  lo.last_order_date
FROM biz b
CROSS JOIN params p
LEFT JOIN last_order lo ON lo.business_id = b.business_id
ORDER BY b.business_id;
