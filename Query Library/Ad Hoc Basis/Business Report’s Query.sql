WITH base AS (
  SELECT
    o.business_id,
    o.pickup_hub_id,
    h.name as pickup_hub_name,
    o.transfer_status_id,
    o.sorted_at::date AS sorted_bd_date
  FROM orders o
  left join hubs h on o.pickup_hub_id = h.id
  WHERE o.sorted_at IS NOT NULL
    AND o.sorted_at >= TIMESTAMP '2026-01-01 00:00:00'
    AND o.sorted_at <  TIMESTAMP '2026-05-01 00:00:00'
    AND o.pickup_hub_id IN (
      39, 144, 43, 124, 158, 36, 101, 140, 59, 100, 123, 176, 81
    )
    AND o.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,37,38,39
    )
)

SELECT
  business_id,
  pickup_hub_id,
  pickup_hub_name,
  COUNT(transfer_status_id) FILTER (
    WHERE sorted_bd_date >= DATE '2026-01-01'
      AND sorted_bd_date <  DATE '2026-02-01'
  ) AS jan_26_processed,

  COUNT(transfer_status_id) FILTER (
    WHERE sorted_bd_date >= DATE '2026-02-01'
      AND sorted_bd_date <  DATE '2026-03-01'
  ) AS feb_26_processed,

  COUNT(transfer_status_id) FILTER (
    WHERE sorted_bd_date >= DATE '2026-03-01'
      AND sorted_bd_date <  DATE '2026-04-01'
  ) AS mar_26_processed,

  COUNT(transfer_status_id) FILTER (
    WHERE sorted_bd_date >= DATE '2026-04-01'
      AND sorted_bd_date <  DATE '2026-05-01'
  ) AS apr_26_processed,

  COUNT(transfer_status_id) AS total_processed_jan_to_apr

FROM base
GROUP BY 1, 2,3
ORDER BY 1, 2,3;
