/* ============================================================
   Orders aging view (UTC+6 display)

   Candidate filter: ONLY orders.sorted_at (+6h) in timeframe
   Then log lookups for only those candidate order_ids

   Outputs:
   - CID, Business ID, System Status, Parcel Current Status
   - delivery_agent_id
   - Pickup/Delivery hub + zone
   - Created at (earliest log)
   - Sorted at (log-based; fallback orders.sorted_at)
   - LMH at (earliest status=13 log)
   - Transfer Status Updated at (latest log)
   - Aging buckets (hours/days/bracket 1..10, 10+)
============================================================ */

WITH
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

/* 1) Candidate orders filtered ONLY by orders.sorted_at (+6h) window */
candidate_orders AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,
    o.transfer_status_id,
    ts.name AS system_status,

    o.delivery_agent_id,

    o.sorted_at  AS orders_sorted_at_raw,

    o.pickup_hub_id,
    o.delivery_hub_id

  FROM orders o
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id

  WHERE
    o.business_id <> 10
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-21 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-21 00:00:00'
),

/* 2) Aggregate logs ONLY for candidate orders */
logs_agg AS (
  SELECT
    ol.order_id,

    /* Created_at: earliest log */
    MIN(ol.created_at) AS created_at_log_raw,

    /* Transfer_status_updated_at: latest log */
    MAX(ol.created_at) AS tsu_log_raw,

    /* LMH_at: earliest status 13 */
    MIN(CASE WHEN ol.current_status = 13 THEN ol.created_at END) AS lmh_log_raw,

    /* Sorted_at (way 1): earliest status excluding 1,2,3,5,6 */
    MIN(CASE WHEN ol.current_status NOT IN (1,2,3,5,6) THEN ol.created_at END) AS sorted_log_raw

  FROM order_logs ol
  JOIN candidate_orders co ON co.order_id = ol.order_id
  GROUP BY ol.order_id
),

/* 3) Base join: hubs + zones + log aggregates */
base AS (
  SELECT
    co.*,

    ph.name AS pickup_hub_name,
    phz.zone_type AS pickup_zone,

    dh.name AS delivery_hub_name,
    dhz.zone_type AS delivery_zone,

    la.created_at_log_raw,
    la.sorted_log_raw,
    la.lmh_log_raw,
    la.tsu_log_raw

  FROM candidate_orders co

  LEFT JOIN hubs ph ON ph.id = co.pickup_hub_id
  LEFT JOIN hubs dh ON dh.id = co.delivery_hub_id

  LEFT JOIN hub_zone_map phz ON phz.hub_id = co.pickup_hub_id
  LEFT JOIN hub_zone_map dhz ON dhz.hub_id = co.delivery_hub_id

  LEFT JOIN logs_agg la ON la.order_id = co.order_id
),

/* 4) Status + effective timestamps (raw UTC) */
calc AS (
  SELECT
    b.*,

    /* Parcel Current Status */
    CASE
      WHEN b.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,40,42,43) THEN 'In Process'
      WHEN b.transfer_status_id IN (15,17,18,21,22) THEN 'Terminal'
      WHEN b.transfer_status_id IN (19,20) THEN 'Lost & Damage'
      ELSE 'Unknown'
    END AS parcel_current_status,

    /* Created_at: earliest log (per your rule) */
    b.created_at_log_raw AS created_at_eff_raw,

    /* Sorted_at:
       way 1: earliest excluded-status log
       way 2: orders.sorted_at
    */
    COALESCE(b.sorted_log_raw, b.orders_sorted_at_raw) AS sorted_at_eff_raw,

    /* LMH_at: earliest status 13 log */
    b.lmh_log_raw AS lmh_at_raw,

    /* Transfer_status_updated_at: latest log */
    b.tsu_log_raw AS tsu_at_raw,

    (NOW()::timestamp) AS now_raw

  FROM base b
),

/* 5) Compute end time in its own CTE (avoids alias issues) */
flow_base AS (
  SELECT
    c.*,
    CASE
      WHEN c.parcel_current_status = 'In Process' THEN c.now_raw
      ELSE c.tsu_at_raw
    END AS end_at_eff_raw
  FROM calc c
),

/* 6) Aging calculations */
flow AS (
  SELECT
    f.*,

    /* Sort -> LMH */
    CASE
      WHEN f.lmh_at_raw IS NOT NULL AND f.sorted_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.lmh_at_raw - f.sorted_at_eff_raw)) / 3600.0, 2)
    END AS sort_to_lmh_hours,

    CASE
      WHEN f.lmh_at_raw IS NOT NULL AND f.sorted_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.lmh_at_raw - f.sorted_at_eff_raw)) / 86400.0, 2)
    END AS sort_to_lmh_days,

    CASE
      WHEN f.lmh_at_raw IS NULL OR f.sorted_at_eff_raw IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (f.lmh_at_raw - f.sorted_at_eff_raw)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(
              1,
              CEIL(
                GREATEST(EXTRACT(EPOCH FROM (f.lmh_at_raw - f.sorted_at_eff_raw)) / 86400.0, 0)
              )
            )::int
          )::text
        END
    END AS sort_to_lmh_days_bracket,

    /* LMH -> Terminal/Now */
    CASE
      WHEN f.lmh_at_raw IS NOT NULL AND f.end_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.lmh_at_raw)) / 3600.0, 2)
    END AS lmh_to_terminal_hours,

    CASE
      WHEN f.lmh_at_raw IS NOT NULL AND f.end_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.lmh_at_raw)) / 86400.0, 2)
    END AS lmh_to_terminal_days,

    CASE
      WHEN f.lmh_at_raw IS NULL OR f.end_at_eff_raw IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.lmh_at_raw)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(
              1,
              CEIL(
                GREATEST(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.lmh_at_raw)) / 86400.0, 0)
              )
            )::int
          )::text
        END
    END AS lmh_to_terminal_days_bracket,

    /* Overall: Sort -> Terminal/Now */
    CASE
      WHEN f.sorted_at_eff_raw IS NOT NULL AND f.end_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.sorted_at_eff_raw)) / 3600.0, 2)
    END AS sort_to_terminal_hours,

    CASE
      WHEN f.sorted_at_eff_raw IS NOT NULL AND f.end_at_eff_raw IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.sorted_at_eff_raw)) / 86400.0, 2)
    END AS sort_to_terminal_days,

    CASE
      WHEN f.sorted_at_eff_raw IS NULL OR f.end_at_eff_raw IS NULL THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.sorted_at_eff_raw)) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(
              1,
              CEIL(
                GREATEST(EXTRACT(EPOCH FROM (f.end_at_eff_raw - f.sorted_at_eff_raw)) / 86400.0, 0)
              )
            )::int
          )::text
        END
    END AS sort_to_terminal_days_bracket

  FROM flow_base f
)

SELECT
  f.consignment_id        AS "CID",
  f.business_id           AS "Business ID",
  f.system_status         AS "System Status",
  f.parcel_current_status AS "Parcel Current Status",

  f.delivery_agent_id     AS "Delivery Agent ID",

  f.pickup_hub_name       AS "Pickup Hub",
  f.pickup_zone           AS "Pickup Zone",
  f.delivery_hub_name     AS "Delivery Hub",
  f.delivery_zone         AS "Delivery Zone",

  /* timestamps (UTC+6 display) */
  (f.created_at_eff_raw + INTERVAL '6 hours') AS "Created at",
  (f.sorted_at_eff_raw  + INTERVAL '6 hours') AS "Sorted at",
  (f.lmh_at_raw         + INTERVAL '6 hours') AS "LMH at",
  (f.tsu_at_raw         + INTERVAL '6 hours') AS "Transfer Status Updated at",

  /* aging outputs */
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
ORDER BY f.orders_sorted_at_raw DESC;
