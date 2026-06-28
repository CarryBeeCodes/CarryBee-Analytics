WITH
/*----------------------------------------------------------
  Hub → zone map by IDs (3PL, CW, etc. as-is)
----------------------------------------------------------*/
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

      -- SUB hubs (including Keraniganj-Ati Bazar & Narayanganj-Bandar, etc.)
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163)
        THEN 'SUB'

      -- Everything else
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
)

SELECT
    o.business_id AS "Business_ID",
    --b.name        AS "Business Name",
    ts.name       AS "Current Status",
    o.consignment_id AS "CID",

    -- +6h local adjustments
    (o.sorted_at + INTERVAL '6 hours') AS "Sorted_at",
    (o.transfer_status_updated_at + INTERVAL '6 hours')
                                       AS "Transfer_status_update_at",

    dh.name                            AS "Delivery Hub",

    -- Zone from hub_zone_map (default OSD)
    COALESCE(hz.zone_type, 'OSD')      AS "Zone",

    -- Month from +6h sorted_at
    TO_CHAR(
      DATE_TRUNC('month', o.sorted_at + INTERVAL '6 hours'),
      'YYYY-MM'
    )                                  AS "Month",

    -- Aging (hrs) between +6h timestamps
    ROUND(
      EXTRACT(
        EPOCH FROM (
          (o.transfer_status_updated_at + INTERVAL '6 hours')
          - (o.sorted_at + INTERVAL '6 hours')
        )
      ) / 3600.0,
      2
    )                                  AS "Aging (Hours)",

    -- Aging Day bucket from +6h timestamps
    CASE 
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) <  24 * 3600 THEN '1'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) <  48 * 3600 THEN '2'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) <  72 * 3600 THEN '3'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) <  96 * 3600 THEN '4'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 120 * 3600 THEN '5'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 144 * 3600 THEN '6'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 168 * 3600 THEN '7'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 192 * 3600 THEN '8'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 216 * 3600 THEN '9'
        WHEN EXTRACT(
               EPOCH FROM (
                 (o.transfer_status_updated_at + INTERVAL '6 hours')
                 - (o.sorted_at + INTERVAL '6 hours')
               )
             ) < 240 * 3600 THEN '10'
        ELSE '10+'
    END                                  AS "Aging Day"

FROM orders o
LEFT JOIN transfer_statuses ts ON o.transfer_status_id = ts.id
LEFT JOIN hubs              dh ON o.delivery_hub_id    = dh.id

-- join to hub_zone_map by hub_id
LEFT JOIN hub_zone_map hz
  ON dh.id = hz.hub_id

WHERE o.transfer_status_id IN (15, 18, 21, 22, 17, 19, 20)
  AND (o.sorted_at + INTERVAL '6 hours')
        BETWEEN TIMESTAMP '2026-01-01 00:00:00'
            AND TIMESTAMP '2026-01-11 23:59:59'
  AND COALESCE(hz.zone_type, 'OSD') IN ('ISD','SUB')   -- keep only ISD/SUB

ORDER BY (o.sorted_at + INTERVAL '6 hours') DESC;
