/* ============================================================
   Orders view (UTC+6 display) — NO order_logs, NO aging

   Candidate filter:
   - COALESCE(orders.sorted_at, orders.created_at) (+6h) in timeframe

   Timestamps ONLY from orders:
   - Created at  = orders.created_at
   - Sorted at   = orders.sorted_at
   - LMH at      = orders.last_mile_at
   - TS updated  = orders.transfer_status_updated_at

   Added from attempt logic:
   - Attempt Count
   - 1st Attempt At

   Attempt source:
   - orders.id = order_runs.order_id
   - order_runs.run_id = runs.id
   - eligible attempts: runs.run_type = 2
   - order_runs.deleted_at IS NULL
   - attempt_at BD = order_runs.created_at + 6 hours

   PLUS:
   - City/Zone names
   - Parcel financials (Tk)
============================================================ */

WITH
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214,226) THEN 'ISD'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (161) THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'
      WHEN h.id IN (10) THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/* 1) Candidate orders filtered by COALESCE(sorted_at, created_at) +6h window */
candidate_orders AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,
    o.transfer_status_id,
    ts.name AS system_status,

    o.delivery_agent_id,

    /* orders timestamps only */
    o.created_at                 AS created_at_raw,
    o.sorted_at                  AS sorted_at_raw,
    o.last_mile_at               AS lmh_at_raw,
    o.transfer_status_updated_at AS tsu_at_raw,

    COALESCE(o.sorted_at, o.created_at) AS sorted_or_created_at_raw,

    o.pickup_hub_id,
    o.delivery_hub_id,

    /* City/Zone */
    o.zone_id,
    o.city_id,
    c.name AS city_name,
    z.name AS zone_name,

    /* Parcel */
    o.weight AS weight,

    /* Money (Tk) */
    (o.collectable_amount / 100.0)              AS collectable_amount_tk,
    (o.collected_amount  / 100.0)               AS collected_amount_tk,
    ROUND((o.cod_fee::numeric      / 100.0), 2) AS cod_fee_tk,
    ROUND((o.delivery_fee::numeric / 100.0), 2) AS delivery_return_fee_tk,
    (o.discount / 100.0)                        AS discount_tk,
    ROUND((o.total_fee::numeric    / 100.0), 2) AS total_fee_tk

  FROM orders o
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
  LEFT JOIN zones z             ON z.id = o.zone_id
  LEFT JOIN cities c            ON c.id = o.city_id

  WHERE
    o.business_id <> 10

    AND COALESCE(o.sorted_at, o.created_at) IS NOT NULL

    AND (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours') >= TIMESTAMP '2026-06-01 00:00:00'
    AND (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours') <  TIMESTAMP '2026-06-17 00:00:00'
),

/* 2) Eligible delivery attempts */
attempt_ranked AS (
  SELECT
    co.order_id,

    orr.id AS order_run_id,
    orr.created_at AS attempt_at_utc,
    orr.created_at + INTERVAL '6 hours' AS attempt_at_bd,

    ROW_NUMBER() OVER (
      PARTITION BY co.order_id
      ORDER BY orr.created_at ASC, orr.id ASC
    ) AS attempt_no

  FROM candidate_orders co

  INNER JOIN order_runs orr
          ON orr.order_id = co.order_id
         AND orr.deleted_at IS NULL

  INNER JOIN runs r
          ON r.id = orr.run_id
         AND r.run_type = 2
),

/* 3) Attempt count + first attempt only */
attempt_pivot AS (
  SELECT
    ar.order_id,

    COUNT(*) AS attempt_count,

    MAX(ar.attempt_at_bd) FILTER (
      WHERE ar.attempt_no = 1
    ) AS first_attempt_at_bd

  FROM attempt_ranked ar
  GROUP BY ar.order_id
),

/* 4) Base join: hubs + zones + attempts */
base AS (
  SELECT
    co.*,

    ph.name AS pickup_hub_name,
    phz.zone_type AS pickup_zone,

    dh.name AS delivery_hub_name,
    dhz.zone_type AS delivery_zone,

    COALESCE(ap.attempt_count, 0) AS attempt_count,
    ap.first_attempt_at_bd

  FROM candidate_orders co

  LEFT JOIN hubs ph
         ON ph.id = co.pickup_hub_id

  LEFT JOIN hubs dh
         ON dh.id = co.delivery_hub_id

  LEFT JOIN hub_zone_map phz
         ON phz.hub_id = co.pickup_hub_id

  LEFT JOIN hub_zone_map dhz
         ON dhz.hub_id = co.delivery_hub_id

  LEFT JOIN attempt_pivot ap
         ON ap.order_id = co.order_id
),

/* 5) Status bucket only */
final AS (
  SELECT
    b.*,

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
)

SELECT
  f.consignment_id        AS "CID",
  f.business_id           AS "Business ID",
  f.system_status         AS "System Status",
  f.parcel_current_status AS "Parcel Current Status",

  f.delivery_agent_id     AS "Delivery Agent ID",

  /* Attempts */
  f.attempt_count AS "Attempt Count",
  TO_CHAR(f.first_attempt_at_bd, 'YYYY-MM-DD HH24:MI:SS') AS "1st Attempt At",

  /* City/Zone */
  f.city_name AS "City Name",
  f.zone_name AS "Zone Name",

  /* Parcel / Financials */
  f.weight                 AS "Weight",
  f.collectable_amount_tk  AS "Collectable Amount",
  f.collected_amount_tk    AS "Collected Amount",
  f.cod_fee_tk             AS "COD Fee",
  f.delivery_return_fee_tk AS "Delivery/Return fee",
  f.discount_tk            AS "Discount",
  f.total_fee_tk           AS "Total fee",

  f.pickup_hub_name   AS "Pickup Hub",
  f.pickup_zone       AS "Pickup Zone",
  f.delivery_hub_name AS "Delivery Hub",
  f.delivery_zone     AS "Delivery Zone",

  /* timestamps UTC+6 display — from orders table */
  f.created_at_raw + INTERVAL '6 hours' AS "Created at",
  f.sorted_at_raw  + INTERVAL '6 hours' AS "Sorted at",
  f.lmh_at_raw     + INTERVAL '6 hours' AS "LMH at",
  f.tsu_at_raw     + INTERVAL '6 hours' AS "Transfer Status Updated at"

FROM final f

WHERE f.transfer_status_id IN (
  4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39
)

ORDER BY
  f.sorted_or_created_at_raw DESC;
