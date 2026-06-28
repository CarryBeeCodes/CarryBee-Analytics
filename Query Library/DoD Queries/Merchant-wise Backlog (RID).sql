/* Orders detail with current status, hubs, zones & aging (UTC+6 timestamps)
   Amounts converted from paisa → taka
   Return processing view for Business ID 10
*/

WITH
/*----------------------------------------------------------
  1) Hub → zone map by IDs (3PL kept as-is; 162,163 as SUB)
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163)
        THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/*----------------------------------------------------------
  2) Order logs aggregation for derived sorted_at
     - first_log_created_at: earliest log for the order (any current_status)
----------------------------------------------------------*/
logs_agg AS (
  SELECT
    ol.order_id,
    MIN(ol.created_at) AS first_log_created_at
  FROM order_logs ol
  GROUP BY ol.order_id
),

/*----------------------------------------------------------
  3) Base orders + hubs + zones + effective sorted_at
----------------------------------------------------------*/
base AS (
  SELECT
    o.*,
    ts.name       AS transfer_status_name,
    dh.name       AS delivery_hub_name,
    ph.name       AS pickup_hub_name,
    dhz.zone_type AS delivery_zone_type,
    phz.zone_type AS pickup_zone_type,

    /* Delivery Division from delivery hub ID */
    CASE
      WHEN dh.id = 10 THEN '3PL'

      WHEN dh.id IN (18,19,20,21,22,50,99,109,115,127)
        THEN 'Barisal'

      WHEN dh.id IN (
        23,24,25,26,27,28,29,30,31,
        55,63,69,86,87,88,89,95,96,97,98,
        105,120,126,135,136,137,142,143,
        148,149,150,151,152
      )
        THEN 'CTG'

      WHEN dh.id IN (1,2,3,4,5,6,7,8,9,71,72,92,145)
        THEN 'Dhaka ISD'

      WHEN dh.id IN (17,32,56,62,70,75,76,79,83,84,85,94,103,106,112,118,119,129,138)
        THEN 'Dhaka OSD'

      WHEN dh.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163)
        THEN 'Dhaka Sub'

      WHEN dh.id IN (48,58,59,60,61,64,65,66,77,82,100,107,121,122,123,128)
        THEN 'Khulna'

      WHEN dh.id IN (33,34,35,67,93,117,133,134)
        THEN 'Mymensingh'

      WHEN dh.id IN (36,37,38,39,40,49,51,80,101,102,125,139,140,144)
        THEN 'Rajshahi'

      WHEN dh.id IN (41,42,43,52,53,54,57,68,104,124,141)
        THEN 'Rangpur'

      WHEN dh.id IN (44,45,46,47,90,108,113,114,116,130,131,132,147)
        THEN 'Sylhet'

      ELSE 'Unknown'
    END AS delivery_division_name,

    /* Effective Sorted At:
       - For status 23: earliest log row (first_log_created_at)
       - Else if orders.sorted_at is present: use it
       - Else: earliest log row (first_log_created_at)
    */
    CASE
      WHEN o.transfer_status_id = 23
        THEN la.first_log_created_at
      WHEN o.sorted_at IS NOT NULL
        THEN o.sorted_at
      ELSE la.first_log_created_at
    END AS effective_sorted_at

  FROM orders o
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
  LEFT JOIN hubs dh              ON dh.id = o.delivery_hub_id
  LEFT JOIN hubs ph              ON ph.id = o.pickup_hub_id
  LEFT JOIN hub_zone_map dhz     ON dhz.hub_id = dh.id
  LEFT JOIN hub_zone_map phz     ON phz.hub_id = ph.id
  LEFT JOIN logs_agg la          ON la.order_id = o.id
  WHERE
    o.business_id = 10
    AND o.transfer_status_id IN (
      -- Processing
      23,24,25,26,27,28,29,30,31,34,35,41,44,45
      -- Terminal (32,33) currently excluded here
    )
    AND (o.created_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-01'
    /* For transfer status 23: keep only orders that actually have logs */
    AND (o.transfer_status_id <> 23 OR la.first_log_created_at IS NOT NULL)
),

/*----------------------------------------------------------
  4) Apply aging logic (hours + days)
----------------------------------------------------------*/
calc AS (
  SELECT
    b.*,

    /* Effective sorted_at in BD time */
    (b.effective_sorted_at + INTERVAL '6 hours') AS effective_sorted_local,

    /* Overall Aging (Hours):
       - If later you include 32,33, they will use TSU vs effective_sorted_at
       - For now (only processing statuses), this is NOW(+6h) - effective_sorted_at(+6h)
    */
    CASE
      WHEN b.transfer_status_id IN (32,33) THEN
        EXTRACT(
          EPOCH FROM (
            (b.transfer_status_updated_at + INTERVAL '6 hours')
            - (b.effective_sorted_at      + INTERVAL '6 hours')
          )
        ) / 3600.0
      ELSE
        EXTRACT(
          EPOCH FROM (
            (NOW() + INTERVAL '6 hours')
            - (b.effective_sorted_at + INTERVAL '6 hours')
          )
        ) / 3600.0
    END AS overall_aging_hours
  FROM base b
)

SELECT
  /* 1) CID */
  c.consignment_id                AS "CID",
  c.merchant_order_id             AS "MID",

  /* 2) Delivery Zone */
  c.delivery_zone_type            AS "Delivery Zone",

  /* 3) Delivery Division */
  c.delivery_division_name        AS "Delivery Division",

  /* 4) Delivery Hub */
  c.delivery_hub_name             AS "Delivery Hub",

  /* 5) Pick Up Hub */
  c.pickup_hub_name               AS "Pick Up Hub",

  /* 6) Pick Up Zone */
  c.pickup_zone_type              AS "Pick Up Zone",

  /* 7) Sorted_at (effective sorted_at in BD time) */
  c.effective_sorted_local        AS "Sorted_at",

  /* 8) Current Aging – actual days (1,2,3,... no 10+) */
  CASE
    WHEN c.overall_aging_hours IS NULL THEN NULL
    ELSE FLOOR(c.overall_aging_hours / 24.0)::int + 1
  END                             AS "Current Aging (Days)",

  /* 9) Transfer Status Name */
  c.transfer_status_name          AS "Transfer Status Name",

  /* 10) Transfer Status Updated at (BD time) */
  (c.transfer_status_updated_at + INTERVAL '6 hours')
                                  AS "Transfer Status Updated at",

  /* 11) Data Added Date (today's BD date) */
  (NOW() + INTERVAL '6 hours')::date
                                  AS "Data Added Date"

FROM calc c
WHERE 1 = 1
  -- If you want to exclude some CIDs, add here:
  -- AND c.consignment_id NOT IN ('R0XXXX1','R0XXXX2',...)
ORDER BY
  c.effective_sorted_local DESC;
