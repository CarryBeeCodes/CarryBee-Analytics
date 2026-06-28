/* Report: Orders with zone_transfer (wrong sort) between 24 Oct and 25 Nov 2025
   One row per order with at least one *effective* zone_transfer action
   (prev_delivery_hub_id <> new_delivery_hub_id).
*/

WITH
/*----------------------------------------------------------
  1) Candidate orders in the sorted_at timeframe (UTC+6)
----------------------------------------------------------*/
candidate_orders AS (
  SELECT
    o.*
  FROM public.orders o
  WHERE
    (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-01 00:00:00'
    --AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-11-28 00:00:00'
    --AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,36,37,38,39,42,43) -- All
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43) -- On going
    AND o.business_id <> 10
),

/*----------------------------------------------------------
  2) Hub → zone map by IDs (new Central / Sub Sort logic)
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

      -- SUB hubs (including new Keraniganj-Ati Bazar & Narayanganj-Bandar)
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'

      -- Everything else
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
),

/*----------------------------------------------------------
  2.5) Current hub per order (last order_logs row)
----------------------------------------------------------*/
current_hub_raw AS (
  SELECT
    ol.order_id,
    -- If hub_id is only in payload, replace the next line with:
    -- NULLIF(ol.payload::jsonb ->> 'hub_id','')::int AS hub_id,
    ol.hub_id AS hub_id,
    ol.created_at,
    ol.id AS order_log_id
  FROM public.order_logs ol
  JOIN candidate_orders co
    ON co.id = ol.order_id
),
current_hub AS (
  SELECT
    order_id,
    hub_id AS current_hub_id
  FROM (
    SELECT
      order_id,
      hub_id,
      ROW_NUMBER() OVER (
        PARTITION BY order_id
        ORDER BY created_at DESC, order_log_id DESC
      ) AS rn
    FROM current_hub_raw
  ) t
  WHERE rn = 1
),

/*----------------------------------------------------------
  3) Raw zone_transfer logs for candidate orders (with safe casts)
----------------------------------------------------------*/
zone_transfer_raw AS (
  SELECT
    ol.order_id,
    ol.id AS order_log_id,
    (ol.created_at + INTERVAL '6 hours') AS zone_transfer_time_utc6,
    NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','')::int AS prev_hub_id,
    NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')::int  AS new_hub_id
  FROM public.order_logs ol
  JOIN candidate_orders co
    ON co.id = ol.order_id
  WHERE
    ol.payload::jsonb ->> 'action' = 'zone_transfer'
    AND (ol.created_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-08 00:00:00'
),

/*----------------------------------------------------------
  4) Keep only *effective* transfers (prev <> new) and assign RN per order
----------------------------------------------------------*/
zone_transfer_logs AS (
  SELECT
    ztr.order_id,
    ztr.order_log_id,
    ztr.zone_transfer_time_utc6,
    ztr.prev_hub_id,
    ztr.new_hub_id,
    ROW_NUMBER() OVER (
      PARTITION BY ztr.order_id
      ORDER BY ztr.zone_transfer_time_utc6, ztr.order_log_id
    ) AS rn
  FROM zone_transfer_raw ztr
  WHERE
    ztr.new_hub_id IS NOT NULL
    AND ztr.prev_hub_id IS DISTINCT FROM ztr.new_hub_id
),

/*----------------------------------------------------------
  5) Attach hub names for prev + new hubs
----------------------------------------------------------*/
zone_transfer_named AS (
  SELECT
    ztl.order_id,
    ztl.order_log_id,
    ztl.zone_transfer_time_utc6,
    ztl.prev_hub_id,
    ztl.new_hub_id,
    ztl.rn,
    ph.name AS prev_hub_name,
    nh.name AS new_hub_name
  FROM zone_transfer_logs ztl
  LEFT JOIN public.hubs ph ON ph.id = ztl.prev_hub_id
  LEFT JOIN public.hubs nh ON nh.id = ztl.new_hub_id
),

/*----------------------------------------------------------
  6) Aggregate per order:
     - Wrong Sort Status (zone_transfer_count)
     - Zone Transfer Hub IDs   (CSV of "prev -> new")
     - Zone Transfer Hub Names (CSV of "PrevName -> NewName")
----------------------------------------------------------*/
zt_agg AS (
  SELECT
    order_id,
    COUNT(*) AS zone_transfer_count,

    -- Sequence of prev -> new hub IDs, in log order
    STRING_AGG(
      prev_hub_id::text || ' -> ' || new_hub_id::text,
      ', '
      ORDER BY zone_transfer_time_utc6, order_log_id
    ) AS zone_transfer_pairs_ids,

    -- Sequence of prev -> new hub NAMES, in the same order
    STRING_AGG(
      COALESCE(prev_hub_name,'') || ' -> ' || COALESCE(new_hub_name,''),
      ', '
      ORDER BY zone_transfer_time_utc6, order_log_id
    ) AS zone_transfer_pairs_names,

    -- First prev hub (for pickup comparison)
    MAX(CASE WHEN rn = 1 THEN prev_hub_id   END) AS first_prev_hub_id,
    MAX(CASE WHEN rn = 1 THEN prev_hub_name END) AS first_prev_hub_name

  FROM zone_transfer_named
  GROUP BY order_id
)

SELECT
  /* Core wrong-sort report fields */

  o.consignment_id                             AS "Consignment ID",

  -- New Wrong Sort Status: +1 if pickup hub ≠ first prev hub
  CASE
    WHEN o.pickup_hub_id IS NOT NULL
         AND zt.first_prev_hub_id IS NOT NULL
         AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN zt.zone_transfer_count + 1
    ELSE zt.zone_transfer_count
  END                                          AS "Wrong Sort Status",

  -- New: include pickup hub as first segment when different
  CASE
    WHEN o.pickup_hub_id IS NOT NULL
         AND zt.first_prev_hub_id IS NOT NULL
         AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN
        o.pickup_hub_id::text || ' -> ' || zt.first_prev_hub_id::text ||
        CASE
          WHEN zt.zone_transfer_pairs_ids IS NOT NULL
            THEN ', ' || zt.zone_transfer_pairs_ids
          ELSE ''
        END
    ELSE
      zt.zone_transfer_pairs_ids
  END                                          AS "Zone Transfer Hub IDs (With Pickup)",

  CASE
    WHEN o.pickup_hub_id IS NOT NULL
         AND zt.first_prev_hub_id IS NOT NULL
         AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN
        COALESCE(ph.name,'') || ' -> ' || COALESCE(zt.first_prev_hub_name,'') ||
        CASE
          WHEN zt.zone_transfer_pairs_names IS NOT NULL
            THEN ', ' || zt.zone_transfer_pairs_names
          ELSE ''
        END
    ELSE
      zt.zone_transfer_pairs_names
  END                                          AS "Zone Transfer Hub Names (With Pickup)",

  (o.sorted_at + INTERVAL '6 hours')           AS "Sorted At",

  /* Order meta */
  o.business_id                                AS "Business ID",
  ts.name                                      AS "Transfer Status Name",
  o.recipient_address                          AS "Recipient Address",

  /* Pickup / Delivery hubs & zones (using new zone logic) */
  ph.name                                      AS "Pickup Hub Name",
  hzm_pickup.zone_type                         AS "Pickup Zone",
  dh.name                                      AS "Delivery Hub Name",
  hzm_delivery.zone_type                       AS "Delivery Zone",
  c.name                                       AS "City",
  z.name                                       AS "Zone",

  /* Current hub (from last order_logs row) */
  --ch.current_hub_id                            AS "Current Hub ID",
  chh.name                                     AS "Current Hub Name",

  /* Money (paisa → taka) */
  ROUND(o.collectable_amount / 100.0, 2)       AS "Collectable Amount",
  ROUND(o.collected_amount   / 100.0, 2)       AS "Collected Amount",
  ROUND(o.delivery_fee       / 100.0, 2)       AS "Order Delivery Fee",
  ROUND(o.cod_fee            / 100.0, 2)       AS "Cash On Delivery Fee",
  ROUND(o.discount           / 100.0, 2)       AS "Discount",
  ROUND(o.total_fee          / 100.0, 2)       AS "Total Fee",

  /* Other */
  o.weight                                     AS "Weight"

FROM candidate_orders o
JOIN zt_agg zt             ON zt.order_id = o.id
LEFT JOIN current_hub ch   ON ch.order_id = o.id
LEFT JOIN public.hubs chh  ON chh.id      = ch.current_hub_id
LEFT JOIN public.transfer_statuses ts ON ts.id = o.transfer_status_id
LEFT JOIN public.hubs ph   ON ph.id      = o.pickup_hub_id
LEFT JOIN public.hubs dh   ON dh.id      = o.delivery_hub_id
LEFT JOIN hub_zone_map hzm_pickup   ON hzm_pickup.hub_id   = ph.id
LEFT JOIN hub_zone_map hzm_delivery ON hzm_delivery.hub_id = dh.id
LEFT JOIN public.cities c ON c.id       = o.city_id
LEFT JOIN public.zones  z ON z.id       = o.zone_id

ORDER BY
  (o.sorted_at + INTERVAL '6 hours') DESC;
