WITH
/* Hub → zone map by IDs (3PL kept as-is; only normalized inside route rules) */
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      -- Dhaka ISD hubs (71 & 72 moved out to Central Warehouse)
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'

      -- Central Warehouse
      WHEN h.id IN (71,72) THEN 'Central Warehouse'

      -- Central Inbound
      WHEN h.id IN (161) THEN 'Central Inbound'

      -- Sub Sort zone hubs
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'

      -- 3PL
      WHEN h.id IN (10) THEN '3PL'

      -- SUB hubs (including new Keraniganj-Ati Bazar & Narayanganj-Bandar)
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168) THEN 'SUB'

      -- Everything else
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
)

SELECT
    o.business_id                             AS "Business_ID",
    ts.name                                   AS "Current Status",
    o.consignment_id                          AS "CID",

    -- Use sorted_at; if NULL, fallback to created_at, then apply BD offset
    (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours') AS "Sorted_at",                  -- BD offset

    (o.transfer_status_updated_at + INTERVAL '6 hours')        AS "Transfer_status_update_at",
    --(o.last_mile_at + INTERVAL '6 hours')                             AS "LMH at",
    dh.name                                   AS "Delivery Hub",

    -- Zone from hub ID map (covers all hubs; COALESCE just in case)
    COALESCE(hzm.zone_type, 'OSD')            AS "Zone",

    TO_CHAR(DATE_TRUNC('month', COALESCE(o.sorted_at, o.created_at)), 'YYYY-MM') AS "Month",

    -- Aging in hours with BD timezone adjustment (+6h)
    ROUND(
      EXTRACT(
        EPOCH FROM (
          (NOW() + INTERVAL '6 hours')
          - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
        )
      ) / 3600
    , 2)                                       AS "Aging (Hours)",

    -- Aging Day bucket based on (NOW - sorted_at) with +6h adjustment
    CASE 
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) <  24 * 3600 THEN '1'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) <  48 * 3600 THEN '2'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) <  72 * 3600 THEN '3'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) <  96 * 3600 THEN '4'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 120 * 3600 THEN '5'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 144 * 3600 THEN '6'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 168 * 3600 THEN '7'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 192 * 3600 THEN '8'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 216 * 3600 THEN '9'
        WHEN EXTRACT(EPOCH FROM ((NOW() + INTERVAL '6 hours') - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours'))) < 240 * 3600 THEN '10'
        ELSE '10+'
    END                                        AS "Aging Day"

FROM orders o
LEFT JOIN transfer_statuses ts ON o.transfer_status_id = ts.id
LEFT JOIN hubs dh              ON o.delivery_hub_id    = dh.id
LEFT JOIN hub_zone_map hzm     ON dh.id                = hzm.hub_id

WHERE o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43)

--o.transfer_status_id IN (7,8,9,10,11,12,13,14,35,16,36,37,38,39,42,43,23,24,25,26,27,28,29,30,31,34,41,44,45) --for RIDs
  AND COALESCE(o.sorted_at, o.created_at) BETWEEN '2025-07-01' AND '2026-01-01'
  AND o.business_id!= 10  -- optional filter
  --AND o.business_id = 10  -- optional filter

ORDER BY COALESCE(o.sorted_at, o.created_at) DESC;
