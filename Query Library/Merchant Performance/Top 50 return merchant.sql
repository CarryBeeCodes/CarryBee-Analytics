/* Last 15 days only (BD offset +6 hours)

Return % (15 days) =
  business_return_15d / business_orders_15d

Contribution to Return % (15 days) =
  business_return_15d / total_return_15d_all_businesses   (NO filters applied to denominator)

Filters (applied only to picking final businesses):
- business_orders_15d > 25
- return_pct_15d > 0.1

Top 50 businesses by return_pct_15d DESC
*/

WITH base AS (
  SELECT
    o.business_id,
    o.consignment_id,
    o.transfer_status_id,
    o.sorted_at
  FROM orders o
  WHERE o.business_id IS NOT NULL
    AND o.transfer_status_id IN (4,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
    -- keeping your original exclusion list; remove if you want all businesses included
    AND o.business_id NOT IN (
      1,2,10,93,96,98,100,101,103,110,111,112,114,118,127,132,134,137,143,146,172,179,262,296,389,
      916,978,984,1441,2055,2398,2520,2963,3762,3840,5237,5378,6201,8046,8050,8051,8086,8230,8252,
      8254,8260,8548,8563,8754,8767,9197,9199,10270,10722,11287,11766,12181,13017
    )
),

per_business_15d AS (
  SELECT
    business_id,
    COUNT(consignment_id) FILTER (
      WHERE (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '15 days')
    ) AS last_15_days_orders,
    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '15 days')
    ) AS last_15_days_return
  FROM base
  GROUP BY business_id
),

total_returns_15d AS (
  -- IMPORTANT: denominator is total returns in last 15 days across ALL business_ids in `base`
  -- (no pb filters like orders>25 or return_pct>0.1 applied here)
  SELECT
    COUNT(consignment_id) AS total_return_15d_all_businesses
  FROM base
  WHERE transfer_status_id = 17
    AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '15 days')
),

scored AS (
  SELECT
    pb.business_id,
    pb.last_15_days_orders,
    pb.last_15_days_return,
    (pb.last_15_days_return::numeric / NULLIF(pb.last_15_days_orders, 0)) AS return_pct_15d,
    (pb.last_15_days_return::numeric / NULLIF(tr.total_return_15d_all_businesses, 0)) AS contribution_to_return_pct_15d
  FROM per_business_15d pb
  CROSS JOIN total_returns_15d tr
)

SELECT
  business_id,
  last_15_days_orders AS "Orders - last 15 days",
  last_15_days_return AS "Return - last 15 days",
  return_pct_15d      AS "Return % (15 days)",
  contribution_to_return_pct_15d AS "Contribution to the Return % (15 days)"
FROM scored
WHERE last_15_days_orders > 25
  AND return_pct_15d > 0.1
ORDER BY return_pct_15d DESC
LIMIT 50;
