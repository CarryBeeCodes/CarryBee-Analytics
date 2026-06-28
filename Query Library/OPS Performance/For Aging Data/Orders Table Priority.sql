/* ============================================================
   Orders aging view (UTC+6 display)
   - CID, Business ID, System Status, Parcel Current Status
   - Pickup/Delivery hub + zone
   - LMH time: orders.last_mile_at else earliest log status=13
   - sorted_at fallback: created_at
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

base AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,
    o.transfer_status_id,
    ts.name AS system_status,

    o.created_at,
    o.sorted_at,
    COALESCE(o.sorted_at, o.created_at) AS sorted_at_eff,

    o.last_mile_at,
    o.transfer_status_updated_at,

    /* pickup + delivery hubs */
    o.pickup_hub_id,
    ph.name AS pickup_hub_name,
    phz.zone_type AS pickup_zone,

    o.delivery_hub_id,
    dh.name AS delivery_hub_name,
    dhz.zone_type AS delivery_zone,

    /* Earliest LMH from logs (status=13) */
    la.lmh_logs_raw,

    /* Effective LMH time: orders.last_mile_at first, else logs */
    COALESCE(o.last_mile_at, la.lmh_logs_raw) AS lmh_at_eff

  FROM orders o
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id

  LEFT JOIN hubs ph ON ph.id = o.pickup_hub_id
  LEFT JOIN hubs dh ON dh.id = o.delivery_hub_id

  LEFT JOIN hub_zone_map phz ON phz.hub_id = o.pickup_hub_id
  LEFT JOIN hub_zone_map dhz ON dhz.hub_id = o.delivery_hub_id

  LEFT JOIN LATERAL (
    SELECT MIN(ol.created_at) AS lmh_logs_raw
    FROM order_logs ol
    WHERE ol.order_id = o.id
      AND ol.current_status = 13
  ) la ON TRUE

  WHERE
    o.business_id <> 10
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-21 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-21 00:00:00'
),

calc AS (
  SELECT
    b.*,

    /* Parcel Current Status */
    CASE
      WHEN b.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,40,42,43)
        THEN 'In Process'
      WHEN b.transfer_status_id IN (15,17,18,21,22)
        THEN 'Terminal'
      WHEN b.transfer_status_id IN (19,20)
        THEN 'Lost & Damage'
      ELSE 'Unknown'
    END AS parcel_current_status,

    (NOW()::timestamp) AS now_raw
  FROM base b
),

flow AS (
  SELECT
    c.*,

    /* End time (still used internally for aging calcs) */
    CASE
      WHEN c.parcel_current_status = 'In Process' THEN c.now_raw
      ELSE c.transfer_status_updated_at
    END AS end_at_eff,

    /* -----------------------------
       Sort -> LMH aging
    ----------------------------- */
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
            GREATEST(
              1,
              CEIL(
                GREATEST(EXTRACT(EPOCH FROM (c.lmh_at_eff - c.sorted_at_eff)) / 86400.0, 0)
              )
            )::int
          )::text
        END
    END AS sort_to_lmh_days_bracket,

    /* -----------------------------
       LMH -> Terminal/Now aging
    ----------------------------- */
    CASE
      WHEN c.lmh_at_eff IS NOT NULL
       AND (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NOT NULL
      THEN ROUND(
        EXTRACT(EPOCH FROM (
          (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
          - c.lmh_at_eff
        )) / 3600.0
      , 2)
    END AS lmh_to_terminal_hours,

    CASE
      WHEN c.lmh_at_eff IS NOT NULL
       AND (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NOT NULL
      THEN ROUND(
        EXTRACT(EPOCH FROM (
          (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
          - c.lmh_at_eff
        )) / 86400.0
      , 2)
    END AS lmh_to_terminal_days,

    CASE
      WHEN c.lmh_at_eff IS NULL OR
           (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NULL
        THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (
                  (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
                  - c.lmh_at_eff
                )) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(
              1,
              CEIL(
                GREATEST(
                  EXTRACT(EPOCH FROM (
                    (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
                    - c.lmh_at_eff
                  )) / 86400.0,
                  0
                )
              )
            )::int
          )::text
        END
    END AS lmh_to_terminal_days_bracket,

    /* -----------------------------
       Overall: Sort -> Terminal/Now aging
    ----------------------------- */
    CASE
      WHEN (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NOT NULL
      THEN ROUND(
        EXTRACT(EPOCH FROM (
          (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
          - c.sorted_at_eff
        )) / 3600.0
      , 2)
    END AS sort_to_terminal_hours,

    CASE
      WHEN (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NOT NULL
      THEN ROUND(
        EXTRACT(EPOCH FROM (
          (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
          - c.sorted_at_eff
        )) / 86400.0
      , 2)
    END AS sort_to_terminal_days,

    CASE
      WHEN (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END) IS NULL
        THEN NULL
      ELSE
        CASE
          WHEN (EXTRACT(EPOCH FROM (
                  (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
                  - c.sorted_at_eff
                )) / 86400.0) > 10 THEN '10+'
          ELSE (
            GREATEST(
              1,
              CEIL(
                GREATEST(
                  EXTRACT(EPOCH FROM (
                    (CASE WHEN c.parcel_current_status = 'In Process' THEN c.now_raw ELSE c.transfer_status_updated_at END)
                    - c.sorted_at_eff
                  )) / 86400.0,
                  0
                )
              )
            )::int
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

  /* Pickup/Delivery hub + zone */
  f.pickup_hub_name       AS "Pickup Hub",
  f.pickup_zone           AS "Pickup Zone",
  f.delivery_hub_name     AS "Delivery Hub",
  f.delivery_zone         AS "Delivery Zone",

  /* Timestamps (UTC+6 display) */
  (f.created_at                 + INTERVAL '6 hours') AS "Created at",
  (f.sorted_at_eff              + INTERVAL '6 hours') AS "Sorted at",
  (f.lmh_at_eff                 + INTERVAL '6 hours') AS "LMH at",
  (f.transfer_status_updated_at + INTERVAL '6 hours') AS "Transfer Status Updated at",

  /* Sort -> LMH aging */
  f.sort_to_lmh_hours        AS "Sort→LMH Aging (Hours)",
  f.sort_to_lmh_days         AS "Sort→LMH Aging (Days)",
  f.sort_to_lmh_days_bracket AS "Sort→LMH Aging Bracket (Days)",

  /* LMH -> Terminal/Now aging */
  f.lmh_to_terminal_hours        AS "LMH→Terminal Aging (Hours)",
  f.lmh_to_terminal_days         AS "LMH→Terminal Aging (Days)",
  f.lmh_to_terminal_days_bracket AS "LMH→Terminal Aging Bracket (Days)",

  /* Overall aging */
  f.sort_to_terminal_hours        AS "Overall Sort→Terminal Aging (Hours)",
  f.sort_to_terminal_days         AS "Overall Sort→Terminal Aging (Days)",
  f.sort_to_terminal_days_bracket AS "Overall Sort→Terminal Aging Bracket (Days)"

FROM flow f
WHERE f.transfer_status_id IN (
  4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
  35,36,37,38,39,40,42,43
)
ORDER BY f.created_at DESC;
