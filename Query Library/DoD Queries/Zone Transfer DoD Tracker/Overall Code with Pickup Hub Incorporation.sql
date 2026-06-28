/* ============================================================
   Wrong Sorting (NEW) = count of order_logs where
   description starts with "Zone transfer processed"
   - One row per order (sorted_at local window)
   - Extracts: hub/city/zone/area change flows + reasons (1..8) + compact reasons
   - Adds a “flat” details column so Excel/CSV won’t lose text after newlines
   - Local time = UTC + 6 hours
   ============================================================ */

WITH
/*----------------------------------------------------------
  0) Params (edit dates here)
----------------------------------------------------------*/
params AS (
  SELECT
    TIMESTAMP '2025-11-01 00:00:00' AS sorted_start_local,
    TIMESTAMP '2025-12-16 00:00:00' AS sorted_end_local
),

/*----------------------------------------------------------
  1) Candidate orders in the sorted_at timeframe (UTC+6)
----------------------------------------------------------*/
candidate_orders AS (
  SELECT o.*
  FROM public.orders o
  JOIN params p ON TRUE
  WHERE
    (o.sorted_at + INTERVAL '6 hours') >= p.sorted_start_local
    AND (o.sorted_at + INTERVAL '6 hours') <  p.sorted_end_local
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43) -- ongoing set
    AND o.business_id <> 10
),

/*----------------------------------------------------------
  2) Hub → zone map by IDs (new Central / Sub Sort logic)
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id IN (71,72)                       THEN 'Central Warehouse'
      WHEN h.id IN (161)                         THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'
      WHEN h.id IN (10)                          THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
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
    ol.hub_id,
    ol.created_at,
    ol.id AS order_log_id
  FROM public.order_logs ol
  JOIN candidate_orders co ON co.id = ol.order_id
),
current_hub AS (
  SELECT order_id, hub_id AS current_hub_id
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
  3) NEW: zone transfers detected by description text
     ("Zone transfer processed" blocks)
     + IDs pulled from payload (more reliable than parsing text)
     + Reason parsed from description (payload usually doesn’t have it)
----------------------------------------------------------*/
zone_transfer_raw AS (
  SELECT
    ol.order_id,
    ol.id AS order_log_id,
    (ol.created_at + INTERVAL '6 hours') AS zone_transfer_time_utc6,

    ol.description AS zone_transfer_description,

    /* IMPORTANT for Excel/CSV: remove newlines so nothing “disappears” after export */
    REGEXP_REPLACE(ol.description, E'[\\r\\n]+', ' ', 'g') AS zone_transfer_description_flat,

    NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','')::int AS prev_hub_id,
    NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')::int  AS new_hub_id,

    NULLIF(ol.payload::jsonb ->> 'prev_city_id','')::int AS prev_city_id,
    NULLIF(ol.payload::jsonb ->> 'new_city_id','')::int  AS new_city_id,

    NULLIF(ol.payload::jsonb ->> 'prev_zone_id','')::int AS prev_zone_id,
    NULLIF(ol.payload::jsonb ->> 'new_zone_id','')::int  AS new_zone_id,

    NULLIF(ol.payload::jsonb ->> 'prev_area_id','')::int AS prev_area_id,
    NULLIF(ol.payload::jsonb ->> 'new_area_id','')::int  AS new_area_id,

    /* Reason line (if missing, we’ll treat as Unknown later) */
    NULLIF(BTRIM(SUBSTRING(ol.description FROM '(?is)Reason:\\s*([^\\r\\n]+)')), '') AS reason_raw

  FROM public.order_logs ol
  JOIN candidate_orders co ON co.id = ol.order_id
  WHERE
    ol.description ILIKE 'Zone transfer processed%'   -- NEW detection
),

/*----------------------------------------------------------
  4) Keep only *effective* transfers (prev <> new) and assign RN
----------------------------------------------------------*/
zone_transfer_logs AS (
  SELECT
    ztr.*,
    COALESCE(NULLIF(ztr.reason_raw,''), 'Unknown') AS reason,
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
  5) Attach names for hubs/cities/zones/areas
----------------------------------------------------------*/
zone_transfer_named AS (
  SELECT
    ztl.*,

    ph.name AS prev_hub_name,
    nh.name AS new_hub_name,

    pc.name AS prev_city_name,
    nc.name AS new_city_name,

    pz.name AS prev_zone_name,
    nz.name AS new_zone_name,

    pa.name AS prev_area_name,
    na.name AS new_area_name

  FROM zone_transfer_logs ztl
  LEFT JOIN public.hubs   ph ON ph.id = ztl.prev_hub_id
  LEFT JOIN public.hubs   nh ON nh.id = ztl.new_hub_id
  LEFT JOIN public.cities pc ON pc.id = ztl.prev_city_id
  LEFT JOIN public.cities nc ON nc.id = ztl.new_city_id
  LEFT JOIN public.zones  pz ON pz.id = ztl.prev_zone_id
  LEFT JOIN public.zones  nz ON nz.id = ztl.new_zone_id
  LEFT JOIN public.areas  pa ON pa.id = ztl.prev_area_id
  LEFT JOIN public.areas  na ON na.id = ztl.new_area_id
),

/*----------------------------------------------------------
  6) Aggregate per order: counts, flows, reasons (1..8), compact reasons
----------------------------------------------------------*/
zt_agg AS (
  SELECT
    order_id,

    COUNT(*) AS zone_transfer_processed_count,

    /* Hub change flow */
    STRING_AGG(
      prev_hub_id::text || ' -> ' || new_hub_id::text,
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) AS hub_change_flow_ids,
    STRING_AGG(
      COALESCE(prev_hub_name,'') || ' -> ' || COALESCE(new_hub_name,''),
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) AS hub_change_flow_names,

    /* City / Zone / Area change flows */
    STRING_AGG(
      COALESCE(prev_city_name,'') || ' ('||COALESCE(prev_city_id::text,'')||') -> ' ||
      COALESCE(new_city_name,'')  || ' ('||COALESCE(new_city_id::text,'')||')',
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) FILTER (WHERE prev_city_id IS NOT NULL OR new_city_id IS NOT NULL) AS city_change_flow,

    STRING_AGG(
      COALESCE(prev_zone_name,'') || ' ('||COALESCE(prev_zone_id::text,'')||') -> ' ||
      COALESCE(new_zone_name,'')  || ' ('||COALESCE(new_zone_id::text,'')||')',
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) FILTER (WHERE prev_zone_id IS NOT NULL OR new_zone_id IS NOT NULL) AS zone_change_flow,

    STRING_AGG(
      COALESCE(prev_area_name,'') || ' ('||COALESCE(prev_area_id::text,'')||') -> ' ||
      COALESCE(new_area_name,'')  || ' ('||COALESCE(new_area_id::text,'')||')',
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) FILTER (WHERE prev_area_id IS NOT NULL OR new_area_id IS NOT NULL) AS area_change_flow,

    /* Reasons */
    MAX(CASE WHEN rn = 1 THEN reason END) AS zone_transfer_reason_1,
    MAX(CASE WHEN rn = 2 THEN reason END) AS zone_transfer_reason_2,
    MAX(CASE WHEN rn = 3 THEN reason END) AS zone_transfer_reason_3,
    MAX(CASE WHEN rn = 4 THEN reason END) AS zone_transfer_reason_4,
    MAX(CASE WHEN rn = 5 THEN reason END) AS zone_transfer_reason_5,
    MAX(CASE WHEN rn = 6 THEN reason END) AS zone_transfer_reason_6,
    MAX(CASE WHEN rn = 7 THEN reason END) AS zone_transfer_reason_7,
    MAX(CASE WHEN rn = 8 THEN reason END) AS zone_transfer_reason_8,

    STRING_AGG(reason, ', ' ORDER BY zone_transfer_time_utc6, order_log_id) AS zone_change_reasons_compact,

    /* Flat details (export-safe) */
    STRING_AGG(zone_transfer_description_flat, ' ||| ' ORDER BY zone_transfer_time_utc6, order_log_id)
      AS zone_transfer_details_flat,

    /* First prev hub for pickup comparison */
    MAX(CASE WHEN rn = 1 THEN prev_hub_id END) AS first_prev_hub_id,
    MAX(CASE WHEN rn = 1 THEN prev_hub_name END) AS first_prev_hub_name

  FROM zone_transfer_named
  GROUP BY order_id
)

SELECT
  /* Core wrong-sort fields */
  o.consignment_id AS "Consignment ID",

  /* Wrong Sort Status = processed count (+1 if pickup hub differs from first prev hub) */
  CASE
    WHEN o.pickup_hub_id IS NOT NULL
     AND zt.first_prev_hub_id IS NOT NULL
     AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN zt.zone_transfer_processed_count + 1
    ELSE zt.zone_transfer_processed_count
  END AS "Wrong Sort Status",

  /* Hub flow (with pickup segment if needed) */
  CASE
    WHEN o.pickup_hub_id IS NOT NULL
     AND zt.first_prev_hub_id IS NOT NULL
     AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN
        o.pickup_hub_id::text || ' -> ' || zt.first_prev_hub_id::text ||
        CASE WHEN zt.hub_change_flow_ids IS NOT NULL THEN ', ' || zt.hub_change_flow_ids ELSE '' END
    ELSE zt.hub_change_flow_ids
  END AS "Delivery Hub Change Flow (IDs)",

  CASE
    WHEN o.pickup_hub_id IS NOT NULL
     AND zt.first_prev_hub_id IS NOT NULL
     AND o.pickup_hub_id <> zt.first_prev_hub_id
      THEN
        COALESCE(ph.name,'') || ' -> ' || COALESCE(zt.first_prev_hub_name,'') ||
        CASE WHEN zt.hub_change_flow_names IS NOT NULL THEN ', ' || zt.hub_change_flow_names ELSE '' END
    ELSE zt.hub_change_flow_names
  END AS "Delivery Hub Change Flow (Names)",

  /* NEW flows */
  zt.city_change_flow AS "City Change Flow",
  zt.zone_change_flow AS "Zone Change Flow",
  zt.area_change_flow AS "Area Change Flow",

  /* NEW reasons */
  zt.zone_transfer_reason_1 AS "Zone Transfer Reason 1",
  zt.zone_transfer_reason_2 AS "Zone Transfer Reason 2",
  zt.zone_transfer_reason_3 AS "Zone Transfer Reason 3",
  zt.zone_transfer_reason_4 AS "Zone Transfer Reason 4",
  zt.zone_transfer_reason_5 AS "Zone Transfer Reason 5",
  zt.zone_transfer_reason_6 AS "Zone Transfer Reason 6",
  zt.zone_transfer_reason_7 AS "Zone Transfer Reason 7",
  zt.zone_transfer_reason_8 AS "Zone Transfer Reason 8",
  zt.zone_change_reasons_compact AS "Zone Change Reasons (Compact)",

  /* Export-safe text backup (no newlines) */
  zt.zone_transfer_details_flat AS "Zone Transfer Details (Flat)",

  (o.sorted_at + INTERVAL '6 hours') AS "Sorted At",

  /* Order meta */
  o.business_id AS "Business ID",
  ts.name       AS "Transfer Status Name",
  o.recipient_address AS "Recipient Address",

  /* Pickup / Delivery hubs & zones */
  ph.name              AS "Pickup Hub Name",
  hzm_pickup.zone_type AS "Pickup Zone",
  dh.name              AS "Delivery Hub Name",
  hzm_delivery.zone_type AS "Delivery Zone",
  c.name AS "City",
  z.name AS "Zone",

  /* Current hub */
  chh.name AS "Current Hub Name",

  /* Money (paisa → taka) */
  ROUND(o.collectable_amount / 100.0, 2) AS "Collectable Amount",
  ROUND(o.collected_amount   / 100.0, 2) AS "Collected Amount",
  ROUND(o.delivery_fee       / 100.0, 2) AS "Order Delivery Fee",
  ROUND(o.cod_fee            / 100.0, 2) AS "Cash On Delivery Fee",
  ROUND(o.discount           / 100.0, 2) AS "Discount",
  ROUND(o.total_fee          / 100.0, 2) AS "Total Fee",

  o.weight AS "Weight"

FROM candidate_orders o
JOIN zt_agg zt ON zt.order_id = o.id

LEFT JOIN current_hub ch  ON ch.order_id = o.id
LEFT JOIN public.hubs chh ON chh.id      = ch.current_hub_id

LEFT JOIN public.transfer_statuses ts ON ts.id = o.transfer_status_id
LEFT JOIN public.hubs ph ON ph.id = o.pickup_hub_id
LEFT JOIN public.hubs dh ON dh.id = o.delivery_hub_id

LEFT JOIN hub_zone_map hzm_pickup   ON hzm_pickup.hub_id   = ph.id
LEFT JOIN hub_zone_map hzm_delivery ON hzm_delivery.hub_id = dh.id

LEFT JOIN public.cities c ON c.id = o.city_id
LEFT JOIN public.zones  z ON z.id = o.zone_id

ORDER BY (o.sorted_at + INTERVAL '6 hours') DESC;
