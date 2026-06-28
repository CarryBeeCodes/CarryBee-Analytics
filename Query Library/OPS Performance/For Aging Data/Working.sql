/* ============================================================
   Orders aging view (UTC+6 display) — Optimized / index-friendly
   + Optional filter: zone_filter = 'ISD' / 'OSD' / 'SUB' / NULL(all)
   Filter applies on DELIVERY hub zone by default.
============================================================ */

WITH
params AS (
  SELECT
    TIMESTAMP '2026-01-01 00:00:00' AS start_local,
    TIMESTAMP '2025-01-23 00:00:00' AS end_local_excl,

    (TIMESTAMP '2026-01-01 00:00:00' - INTERVAL '6 hours') AS start_utc,
    (TIMESTAMP '2025-01-23 00:00:00' - INTERVAL '6 hours') AS end_utc_excl,

    /* ✅ set to 'ISD' / 'OSD' / 'SUB' ; keep NULL for all */
    NULL::text AS zone_filter,

    NOW()::timestamp AS now_raw
),

hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (161) THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'
      WHEN h.id IN (10) THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/* 1) Candidate orders (index-friendly UTC filter + optional zone filter applied early) */
candidate_orders AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,
    o.transfer_status_id,
    ts.name AS system_status,

    o.delivery_agent_id,

    o.created_at,
    o.sorted_at,
    COALESCE(o.sorted_at, o.created_at) AS sorted_at_eff,

    o.last_mile_at,
    o.transfer_status_updated_at,

    o.pickup_hub_id,
    o.delivery_hub_id,

    /* City/Zone */
    o.city_id,
    c.name AS city_name,
    o.zone_id,
    z.name AS zone_name

  FROM orders o
  JOIN params p ON TRUE
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
  LEFT JOIN cities c ON c.id = o.city_id
  LEFT JOIN zones  z ON z.id = o.zone_id

  /* ✅ join hub_zone_map for early zone filtering */
  LEFT JOIN hub_zone_map dzf ON dzf.hub_id = o.delivery_hub_id   -- delivery zone filter
  -- LEFT JOIN hub_zone_map pzf ON pzf.hub_id = o.pickup_hub_id  -- (optional) pickup zone filter

  WHERE
    o.business_id <> 10
    AND o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc_excl

    /* ✅ optional zone filter */
    AND (
      p.zone_filter IS NULL
      OR dzf.zone_type = p.zone_filter
      -- OR pzf.zone_type = p.zone_filter   -- switch to pickup zone if you want
    )
),

/* 2) Aggregate logs ONLY for candidate orders (LMH = earliest status=13) */
logs_agg AS (
  SELECT
    ol.order_id,
    MIN(CASE WHEN ol.current_status = 13 THEN ol.created_at END) AS lmh_log_raw
  FROM order_logs ol
  JOIN candidate_orders co ON co.order_id = ol.order_id
  GROUP BY ol.order_id
),

/* 3) Join hubs + hub zones + logs */
base AS (
  SELECT
    co.*,

    ph.name AS pickup_hub_name,
    phz.zone_type AS pickup_zone,

    dh.name AS delivery_hub_name,
    dhz.zone_type AS delivery_zone,

    la.lmh_log_raw,

    COALESCE(co.last_mile_at, la.lmh_log_raw) AS lmh_at_eff

  FROM candidate_orders co
  LEFT JOIN hubs ph ON ph.id = co.pickup_hub_id
  LEFT JOIN hubs dh ON dh.id = co.delivery_hub_id
  LEFT JOIN hub_zone_map phz ON phz.hub_id = co.pickup_hub_id
  LEFT JOIN hub_zone_map dhz ON dhz.hub_id = co.delivery_hub_id
  LEFT JOIN logs_agg la ON la.order_id = co.order_id
),

calc AS (
  SELECT
    b.*,
    p.now_raw,

    CASE
      WHEN b.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,40,42,43)
        THEN 'In Process'
      WHEN b.transfer_status_id IN (15,17,18,21,22)
        THEN 'Terminal'
      WHEN b.transfer_status_id IN (19,20)
        THEN 'Lost & Damage'
      ELSE 'Unknown'
    END AS parcel_current_status

  FROM base b
  JOIN params p ON TRUE
),

flow AS (
  SELECT
    c.*,

    CASE
      WHEN c.parcel_current_status = 'In Process' THEN c.now_raw
      ELSE c.transfer_status_updated_at
    END AS end_at_eff,

    /* Sort -> LMH */
    CASE
      WHEN c.lmh_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.lmh_at_eff - c.sorted_at_eff)) / 3600.0, 2)
    END AS sort_to_lmh_hours,

    CASE
      WHEN c.lmh_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.lmh_at_eff - c.sorted_at_eff)) / 86400.0, 2)
    END AS sort_to_lmh_days,

    CASE
      WHEN c.lmh_at_eff IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (c.lmh_at_eff - c.sorted_at_eff)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(1, CEIL(GREATEST(EXTRACT(EPOCH FROM (c.lmh_at_eff - c.sorted_at_eff)) / 86400.0, 0)))::int
          )::text
        END
    END AS sort_to_lmh_days_bracket,

    /* LMH -> Terminal/Now */
    CASE
      WHEN c.lmh_at_eff IS NOT NULL AND c.end_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.end_at_eff - c.lmh_at_eff)) / 3600.0, 2)
    END AS lmh_to_terminal_hours,

    CASE
      WHEN c.lmh_at_eff IS NOT NULL AND c.end_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.end_at_eff - c.lmh_at_eff)) / 86400.0, 2)
    END AS lmh_to_terminal_days,

    CASE
      WHEN c.lmh_at_eff IS NULL OR c.end_at_eff IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (c.end_at_eff - c.lmh_at_eff)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(1, CEIL(GREATEST(EXTRACT(EPOCH FROM (c.end_at_eff - c.lmh_at_eff)) / 86400.0, 0)))::int
          )::text
        END
    END AS lmh_to_terminal_days_bracket,

    /* Overall */
    CASE
      WHEN c.end_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.end_at_eff - c.sorted_at_eff)) / 3600.0, 2)
    END AS sort_to_terminal_hours,

    CASE
      WHEN c.end_at_eff IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (c.end_at_eff - c.sorted_at_eff)) / 86400.0, 2)
    END AS sort_to_terminal_days,

    CASE
      WHEN c.end_at_eff IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (c.end_at_eff - c.sorted_at_eff)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(1, CEIL(GREATEST(EXTRACT(EPOCH FROM (c.end_at_eff - c.sorted_at_eff)) / 86400.0, 0)))::int
          )::text
        END
    END AS sort_to_terminal_days_bracket

  FROM calc c
)

SELECT
  f.consignment_id        AS "CID",
  f.business_id           AS "Business ID",
  f.system_status         AS "System Status",
  f.parcel_current_status AS "Parcel Current Status",

  f.delivery_agent_id     AS "Delivery Agent ID",

  f.city_id               AS "City ID",
  f.city_name             AS "City Name",
  f.zone_id               AS "Zone ID",
  f.zone_name             AS "Zone Name",

  f.pickup_hub_name       AS "Pickup Hub",
  f.pickup_zone           AS "Pickup Zone",
  f.delivery_hub_name     AS "Delivery Hub",
  f.delivery_zone         AS "Delivery Zone",

  (f.created_at                 + INTERVAL '6 hours') AS "Created at",
  (f.sorted_at_eff              + INTERVAL '6 hours') AS "Sorted at",
  (f.lmh_at_eff                 + INTERVAL '6 hours') AS "LMH at",
  (f.transfer_status_updated_at + INTERVAL '6 hours') AS "Transfer Status Updated at",

  f.sort_to_lmh_hours        AS "Sort→LMH Aging (Hours)",
  f.sort_to_lmh_days         AS "Sort→LMH Aging (Days)",
  f.sort_to_lmh_days_bracket AS "Sort→LMH Aging Bracket (Days)",

  f.lmh_to_terminal_hours        AS "LMH→Terminal Aging (Hours)",
  f.lmh_to_terminal_days         AS "LMH→Terminal Aging (Days)",
  f.lmh_to_terminal_days_bracket AS "LMH→Terminal Aging Bracket (Days)",

  f.sort_to_terminal_hours        AS "Overall Sort→Terminal Aging (Hours)",
  f.sort_to_terminal_days         AS "Overall Sort→Terminal Aging (Days)",
  f.sort_to_terminal_days_bracket AS "Overall Sort→Terminal Aging Bracket (Days)"

FROM flow f
WHERE f.transfer_status_id IN (
  4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
  35,36,37,38,39,40,42,43
)
ORDER BY f.created_at DESC;
