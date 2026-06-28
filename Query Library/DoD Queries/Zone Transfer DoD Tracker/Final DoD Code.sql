/* ============================================================
   Wrong Sorting (Effective zone_transfer only)

   OUTPUT SEQUENCE (as requested):
   Consignment ID, Wrong Sort Status, Zone Transfer Hubs, Zone Transfer Reasons,
   Zone Change Log, Recipient Address Log,
   Initial Recipient Address, Initial City Name, Initial Zone Name, Initial Delivery Hub,
   Printed Sticker, Sorted At, Business ID, Transfer Status Name,
   Final Recipient Address, Pickup Hub Name, Pickup Zone,
   1st Delivery Hub Name, 1st Delivery Hub Zone,
   Current Hub Name, Delivery Hub Name, Delivery Zone,
   City, Zone
   ============================================================ */

WITH
params AS (
  SELECT
    TIMESTAMP '2025-11-01 00:00:00' AS sorted_start_local,
    TIMESTAMP '2026-01-01 00:00:00' AS sorted_end_local,

    /* Local(UTC+6) -> UTC bounds for index-friendly filter */
    (TIMESTAMP '2025-11-01 00:00:00' - INTERVAL '6 hours') AS start_utc,
    (TIMESTAMP '2026-01-01 00:00:00' - INTERVAL '6 hours') AS end_utc
),

/* 1) Candidate orders using UTC bounds */
candidate_orders AS (
  SELECT o.*
  FROM public.orders o
  JOIN params p ON TRUE
  WHERE
    o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43)
    AND o.business_id <> 10
),

/* A) Initial request details from first "Order has been created" log */
initial_created_log AS (
  SELECT
    ol.order_id,
    ROW_NUMBER() OVER (
      PARTITION BY ol.order_id
      ORDER BY ol.created_at ASC, ol.id ASC
    ) AS rn,
    NULLIF(ol.payload::jsonb ->> 'ReqCityId','')::int AS req_city_id,
    NULLIF(ol.payload::jsonb ->> 'ReqZoneId','')::int AS req_zone_id,
    NULLIF(BTRIM(ol.payload::jsonb ->> 'recipient_address'), '') AS initial_recipient_address
  FROM public.order_logs ol
  JOIN candidate_orders co ON co.id = ol.order_id
  WHERE ol.description ILIKE 'Order has been created%'
),

initial_details AS (
  SELECT
    order_id,
    req_city_id,
    req_zone_id,
    initial_recipient_address
  FROM initial_created_log
  WHERE rn = 1
),

/* B) ReqZoneId -> hub_coverages -> hub_id (exclude special hubs; pick one hub per zone) */
initial_zone_hub_map AS (
  SELECT
    hc.zone_id,
    MIN(hc.hub_id) AS hub_id
  FROM public.hub_coverages hc
  WHERE hc.zone_id IS NOT NULL
    AND hc.hub_id IS NOT NULL
    AND hc.hub_id NOT IN (71,153,154,155,156,157,158,159,73,72,10,161)
    AND hc.deleted_at IS NULL
  GROUP BY hc.zone_id
),

/* 2) Effective zone_transfer logs only (hub-change confirmed by payload) */
zone_transfer_effective AS (
  SELECT
    ol.order_id,
    ol.id AS order_log_id,
    (ol.created_at + INTERVAL '6 hours') AS zone_transfer_time_utc6,
    ol.description,
    REGEXP_REPLACE(ol.description, E'[\\r\\n]+', ' ', 'g') AS zone_transfer_details_flat,
    NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','')::int AS prev_delivery_hub_id,
    NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')::int  AS new_delivery_hub_id
  FROM public.order_logs ol
  JOIN candidate_orders co ON co.id = ol.order_id
  WHERE
    ol.description ILIKE 'Zone transfer processed%'
    AND (ol.payload::jsonb ->> 'action') = 'zone_transfer'
    AND NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','') IS NOT NULL
    AND NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')  IS NOT NULL
    AND NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','')::int
        IS DISTINCT FROM NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')::int
),

/* 3) Printed sticker flag */
sticker_flag AS (
  SELECT
    co.id AS order_id,
    CASE
      WHEN MAX(
        CASE
          WHEN ol.description ILIKE '%New sticker has been printed for zone-transferred order%' THEN 1
          ELSE 0
        END
      ) = 1
      THEN 'Yes' ELSE 'No'
    END AS printed_sticker
  FROM candidate_orders co
  LEFT JOIN public.order_logs ol ON ol.order_id = co.id
  GROUP BY co.id
),

/* 4) Current hub per order (last order_logs row) */
current_hub AS (
  SELECT order_id, hub_id AS current_hub_id
  FROM (
    SELECT
      ol.order_id,
      ol.hub_id,
      ROW_NUMBER() OVER (
        PARTITION BY ol.order_id
        ORDER BY ol.created_at DESC, ol.id DESC
      ) AS rn
    FROM public.order_logs ol
    JOIN candidate_orders co ON co.id = ol.order_id
  ) t
  WHERE rn = 1
),

/* 5) Hub zone map */
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id IN (71,72)                       THEN 'Central Warehouse'
      WHEN h.id IN (161)                         THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'
      WHEN h.id IN (10)                          THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
),

/* 6) Parse City/Zone/Recipient Address/Reason from description + attach hub names */
zone_transfer_parsed AS (
  SELECT
    zte.*,
    ph.name AS prev_hub_name,
    nh.name AS new_hub_name,

    NULLIF(BTRIM((regexp_match(zte.description, E'City:[[:space:]]*([^\\r\\n]+)', 'i'))[1]), '') AS city_change,
    NULLIF(BTRIM((regexp_match(zte.description, E'Zone:[[:space:]]*([^\\r\\n]+)', 'i'))[1]), '') AS zone_change,

    NULLIF(BTRIM((regexp_match(zte.description, E'Recipient Address:[[:space:]]*([^\\r\\n]+)', 'i'))[1]), '') AS recipient_address_flow,

    NULLIF(BTRIM((regexp_match(zte.description, E'Reason:[[:space:]]*([^\\r\\n]+)', 'i'))[1]), '') AS reason
  FROM zone_transfer_effective zte
  LEFT JOIN public.hubs ph ON ph.id = zte.prev_delivery_hub_id
  LEFT JOIN public.hubs nh ON nh.id = zte.new_delivery_hub_id
),

/* 7) Rank transfers per order */
zone_transfer_ranked AS (
  SELECT
    ztp.*,
    ROW_NUMBER() OVER (
      PARTITION BY ztp.order_id
      ORDER BY ztp.zone_transfer_time_utc6, ztp.order_log_id
    ) AS rn
  FROM zone_transfer_parsed ztp
),

/* 8) Aggregate per order */
zt_agg AS (
  SELECT
    order_id,
    COUNT(*) AS wrong_sort_status,

    STRING_AGG(
      COALESCE(prev_hub_name,'') || ' ('||prev_delivery_hub_id::text||') -> ' ||
      COALESCE(new_hub_name,'')  || ' ('||new_delivery_hub_id::text||')',
      ', ' ORDER BY zone_transfer_time_utc6, order_log_id
    ) AS zone_transfer_hubs,

    MAX(CASE WHEN rn = 1 THEN prev_hub_name END) AS first_delivery_hub_name,
    MAX(CASE WHEN rn = 1 THEN prev_delivery_hub_id END) AS first_delivery_hub_id,

    STRING_AGG(reason, ', ' ORDER BY zone_transfer_time_utc6, order_log_id)
      FILTER (WHERE reason IS NOT NULL) AS zone_change_reasons,

    /* NOTE: keeping your existing output mapping:
       - "Zone Change Log" output uses zone_change_flow (Zone parsed values)
       - Raw flat log remains available as zone_change_log / zone_transfer_details_flat_all if needed
    */
    STRING_AGG(zone_transfer_details_flat, ' ||| ' ORDER BY zone_transfer_time_utc6, order_log_id)
      AS zone_change_log,

    STRING_AGG(recipient_address_flow, ' ||| ' ORDER BY zone_transfer_time_utc6, order_log_id)
      FILTER (WHERE recipient_address_flow IS NOT NULL) AS recipient_address_log,

    STRING_AGG(city_change, ', ' ORDER BY zone_transfer_time_utc6, order_log_id)
      FILTER (WHERE city_change IS NOT NULL) AS city_change_flow,

    STRING_AGG(zone_change, ', ' ORDER BY zone_transfer_time_utc6, order_log_id)
      FILTER (WHERE zone_change IS NOT NULL) AS zone_change_flow,

    STRING_AGG(zone_transfer_details_flat, ' ||| ' ORDER BY zone_transfer_time_utc6, order_log_id)
      AS zone_transfer_details_flat_all

  FROM zone_transfer_ranked
  GROUP BY order_id
)

SELECT
  /* === Requested column order starts === */
  o.consignment_id                   AS "Consignment ID",
  zt.wrong_sort_status               AS "Wrong Sort Status",
  zt.zone_transfer_hubs              AS "Zone Transfer Hubs",
  zt.zone_change_reasons             AS "Zone Transfer Reasons",
  zt.zone_change_flow                AS "Zone Change Log",
  zt.recipient_address_log           AS "Recipient Address Log",

  idt.initial_recipient_address      AS "Initial Recipient Address",
  ic.name                            AS "Initial City Name",
  iz.name                            AS "Initial Zone Name",
  ih.name                            AS "Initial Delivery Hub",

  sf.printed_sticker                 AS "Printed Sticker",
  (o.sorted_at + INTERVAL '6 hours') AS "Sorted At",
  o.business_id                      AS "Business ID",
  ts.name                            AS "Transfer Status Name",
  o.recipient_address                AS "Final Recipient Address",
  ph.name                            AS "Pickup Hub Name",
  hzm_pickup.zone_type               AS "Pickup Zone",
  zt.first_delivery_hub_name         AS "1st Delivery Hub Name",
  hzm_first.zone_type                AS "1st Delivery Hub Zone",
  chh.name                           AS "Current Hub Name",
  dh.name                            AS "Delivery Hub Name",
  hzm_delivery.zone_type             AS "Delivery Zone",
  c.name                             AS "City",
  z.name                             AS "Zone"
  /* === Requested column order ends === */

FROM candidate_orders o
JOIN zt_agg zt ON zt.order_id = o.id

LEFT JOIN sticker_flag sf ON sf.order_id = o.id
LEFT JOIN public.transfer_statuses ts ON ts.id = o.transfer_status_id

LEFT JOIN current_hub ch  ON ch.order_id = o.id
LEFT JOIN public.hubs chh ON chh.id      = ch.current_hub_id

LEFT JOIN public.hubs ph ON ph.id = o.pickup_hub_id
LEFT JOIN hub_zone_map hzm_pickup ON hzm_pickup.hub_id = o.pickup_hub_id

LEFT JOIN public.hubs dh ON dh.id = o.delivery_hub_id
LEFT JOIN hub_zone_map hzm_delivery ON hzm_delivery.hub_id = o.delivery_hub_id

LEFT JOIN hub_zone_map hzm_first ON hzm_first.hub_id = zt.first_delivery_hub_id

LEFT JOIN public.cities c ON c.id = o.city_id
LEFT JOIN public.zones  z ON z.id = o.zone_id

/* Initial snapshot joins */
LEFT JOIN initial_details idt ON idt.order_id = o.id
LEFT JOIN public.cities ic ON ic.id = idt.req_city_id
LEFT JOIN public.zones  iz ON iz.id = idt.req_zone_id
LEFT JOIN initial_zone_hub_map izhm ON izhm.zone_id = idt.req_zone_id
LEFT JOIN public.hubs ih ON ih.id = izhm.hub_id

ORDER BY (o.sorted_at + INTERVAL '6 hours') DESC;
