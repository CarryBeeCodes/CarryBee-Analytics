WITH
/*----------------------------------------------------------
  1) Hub → zone map by IDs (3PL kept as-is, 162/163 as SUB)
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/*----------------------------------------------------------
  2) Base raw: hubs, zones, division, effective sorted_at (+6h)
----------------------------------------------------------*/
base_raw AS (
  SELECT
    o.consignment_id,
    o.merchant_order_id,

    -- Hubs & zones
    dh.name                        AS delivery_hub,
    COALESCE(dhz.zone_type, 'OSD') AS delivery_zone,
    ph.name                        AS pickup_hub,
    COALESCE(phz.zone_type, 'OSD') AS pickup_zone,

    -- Delivery Division based on delivery hub ID
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
    END AS delivery_division,

    -- Effective sorted_at in local time (+6h), fallback to created_at
    COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'
      AS effective_sorted_local,

    ts.name AS transfer_status_name,
    (o.transfer_status_updated_at + INTERVAL '6 hours')
      AS transfer_status_updated_at_bd

  FROM orders o
  LEFT JOIN transfer_statuses ts ON o.transfer_status_id = ts.id
  LEFT JOIN hubs dh              ON o.delivery_hub_id    = dh.id
  LEFT JOIN hub_zone_map dhz     ON dh.id                = dhz.hub_id
  LEFT JOIN hubs ph              ON o.pickup_hub_id      = ph.id
  LEFT JOIN hub_zone_map phz     ON ph.id                = phz.hub_id

  WHERE
        o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43)
    AND o.sorted_at BETWEEN TIMESTAMP '2025-07-01 00:00:00'
                        AND TIMESTAMP '2025-12-07 23:59:59'
    AND o.business_id = 290
),

/*----------------------------------------------------------
  3) Add actual aging in days (1,2,3,... no 10+ cap)
     Logic is extension of your old buckets:
     aging_day = floor(diff_days) + 1   (so day1 = [0,1), day2 = [1,2), etc)
----------------------------------------------------------*/
base AS (
  SELECT
    br.*,
    br.effective_sorted_local AS sorted_at_bd,
    GREATEST(
      1,
      FLOOR(
        EXTRACT(
          EPOCH FROM ((NOW() + INTERVAL '6 hours') - br.effective_sorted_local)
        ) / 86400.0
      )::int + 1
    ) AS aging_days
  FROM base_raw br
)

SELECT
  b.consignment_id                AS "CID",
  b.merchant_order_id             AS "Merchant Order ID",
  b.delivery_zone                 AS "Delivery Zone",
  b.delivery_division             AS "Delivery Division",
  b.delivery_hub                  AS "Delivery Hub",
  b.pickup_hub                    AS "Pick Up Hub",
  b.pickup_zone                   AS "Pick Up Zone",
  b.sorted_at_bd                  AS "Sorted_at",
  b.aging_days                    AS "Current Aging (Days)",
  b.transfer_status_name          AS "Transfer Status Name",
  b.transfer_status_updated_at_bd AS "Transfer Status Updated at",
  (NOW() + INTERVAL '6 hours')::date
                                  AS "Data Added Date"
FROM base b
-- Optional exclusion if you want to drop some CIDs:
-- WHERE b.consignment_id NOT IN ('R0XXXX1', 'R0XXXX2', ...)
ORDER BY
  b.sorted_at_bd DESC;
