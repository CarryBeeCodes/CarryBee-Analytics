/* ============================================================
   Delivery-hub wise processed orders (day-by-day columns)
   Local (UTC+6) window: 2026-01-15 00:00:00  -> 2026-02-03 00:00:00 (exclusive)
   Filters:
     - business_id <> 10
     - transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
   Output:
     - Delivery Hub Name
     - One column per BD-local day (15 Jan ... 02 Feb)
============================================================ */

WITH params AS (
  SELECT
    TIMESTAMP '2026-01-15 00:00:00' AS start_local,
    TIMESTAMP '2026-02-04 00:00:00' AS end_local_excl
),
base AS (
  SELECT
    o.delivery_hub_id,
    (o.sorted_at + INTERVAL '6 hours')::date AS sorted_bd_date,
    o.consignment_id
  FROM orders o
  JOIN params p ON TRUE
  WHERE o.sorted_at IS NOT NULL
    -- index-friendly UTC bounds derived from local window (UTC+6)
    AND o.sorted_at >= (p.start_local - INTERVAL '6 hours')
    AND o.sorted_at <  (p.end_local_excl - INTERVAL '6 hours')

    AND o.business_id <> 10
    AND o.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,38,39
    )
)
SELECT
  h.name AS "Hub Name",

  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-15') AS "15 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-16') AS "16 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-17') AS "17 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-18') AS "18 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-19') AS "19 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-20') AS "20 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-21') AS "21 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-22') AS "22 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-23') AS "23 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-24') AS "24 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-25') AS "25 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-26') AS "26 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-27') AS "27 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-28') AS "28 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-29') AS "29 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-30') AS "30 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-01-31') AS "31 Jan",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-02-01') AS "01 Feb",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-02-02') AS "02 Feb",
  COUNT(DISTINCT b.consignment_id) FILTER (WHERE b.sorted_bd_date = DATE '2026-02-03') AS "03 Feb"
FROM base b
LEFT JOIN hubs h ON h.id = b.delivery_hub_id
GROUP BY h.name
ORDER BY h.name;
