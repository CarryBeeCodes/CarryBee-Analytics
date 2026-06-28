WITH
/*----------------------------------------------------------
  1) Hub → zone map by IDs (3PL kept as-is)
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/*----------------------------------------------------------
  2) Base set with Aging Day bucket (integer-style, 1–10, 10+)
     using effective_sorted_at = COALESCE(sorted_at, created_at)
----------------------------------------------------------*/
base AS (
  SELECT
    o.consignment_id,

    -- Hubs
    dh.name                        AS delivery_hub,
    COALESCE(dhz.zone_type, 'OSD') AS delivery_zone,

    ph.name                        AS pickup_hub,
    COALESCE(phz.zone_type, 'OSD') AS pickup_zone,

    -- Effective sorted_at (fallback to created_at if sorted_at is NULL)
    COALESCE(o.sorted_at, o.created_at)              AS effective_sorted_at,
    (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
                                                     AS sorted_at_bd,

    ts.name                        AS transfer_status_name,
    (o.transfer_status_updated_at + INTERVAL '6 hours') AS tsu_at,

    /* Aging Day bucket based on (NOW - effective_sorted_at) with +6h adjustment */
    CASE 
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) <  24 * 3600 THEN '1'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) <  48 * 3600 THEN '2'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) <  72 * 3600 THEN '3'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) <  96 * 3600 THEN '4'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 120 * 3600 THEN '5'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 144 * 3600 THEN '6'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 168 * 3600 THEN '7'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 192 * 3600 THEN '8'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 216 * 3600 THEN '9'
      WHEN EXTRACT(
             EPOCH FROM (
               (NOW() + INTERVAL '6 hours')
               - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) < 240 * 3600 THEN '10'
      ELSE '10+'
    END AS aging_day

  FROM orders o
  LEFT JOIN transfer_statuses ts ON o.transfer_status_id = ts.id
  LEFT JOIN hubs dh              ON o.delivery_hub_id    = dh.id
  LEFT JOIN hub_zone_map dhz     ON dh.id                = dhz.hub_id
  LEFT JOIN hubs ph              ON o.pickup_hub_id      = ph.id
  LEFT JOIN hub_zone_map phz     ON ph.id                = phz.hub_id

  WHERE
        o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43)
    AND o.sorted_at BETWEEN TIMESTAMP '2025-07-01' AND TIMESTAMP '2025-12-29'
    AND o.business_id <> 10
    AND o.consignment_id NOT IN (
      'F1122C8CAGU',
    )
)

/*----------------------------------------------------------
  3) Final filter by zone-specific aging thresholds
     - OSD / 3PL: 7 days and above
     - ISD / SUB: 5 days and above
----------------------------------------------------------*/
SELECT
  b.consignment_id       AS "Consignment ID",
  b.delivery_zone        AS "Delivery Zone",
  b.delivery_hub         AS "Delivery Hub",
  b.pickup_zone          AS "Pickup Zone",
  b.pickup_hub           AS "Pickup Hub",
  b.sorted_at_bd         AS "Sorted at (+6h)",
  b.aging_day            AS "Aging (Days)",
  b.transfer_status_name AS "Transfer Status",
  b.tsu_at               AS "TSU_at"
FROM base b
WHERE
  (
    b.delivery_zone IN ('OSD', '3PL')
    AND b.aging_day IN ('6','7','8','9','10','10+')
  )
  OR
  (
    b.delivery_zone IN ('ISD', 'SUB')
    AND b.aging_day IN ('4','5','6','7','8','9','10','10+')
  )
ORDER BY
  b.sorted_at_bd DESC;
