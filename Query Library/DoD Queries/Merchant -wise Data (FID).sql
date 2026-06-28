/* Orders detail with current status, hubs, zones, attempts, zone transfer & aging
   - UTC+6 timestamps
   - Amounts converted from paisa → taka
   - Aging uses sorted_at, fallback created_at
   - Final Fee logic:
       transfer_status_id = 17  => delivery_fee - discount
       else                     => delivery_fee + cod_fee - discount
*/

WITH
/* Hub → zone map by IDs */
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      -- Dhaka ISD hubs
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214,226,233) THEN 'ISD'

      -- Central Warehouse
      WHEN h.id IN (71,72) THEN 'Central Warehouse'

      -- Central Inbound
      WHEN h.id IN (161) THEN 'Central Inbound'

      -- Sub Sort zone hubs
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'

      -- 3PL
      WHEN h.id IN (10) THEN '3PL'

      -- SUB hubs
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194) THEN 'SUB'

      -- Everything else
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

/* Base order data */
base AS (
  SELECT
    o.*,

    /* Aging base:
       sorted_at if available, otherwise created_at
    */
    COALESCE(o.sorted_at, o.created_at) AS aging_base_at,

    ts.name AS transfer_status_name,

    dh.name AS delivery_hub_name,
    ph.name AS pickup_hub_name,

    dhz.zone_type AS delivery_zone_type,
    phz.zone_type AS pickup_zone_type

  FROM orders o

  LEFT JOIN transfer_statuses ts
         ON ts.id = o.transfer_status_id

  LEFT JOIN hubs dh
         ON dh.id = o.delivery_hub_id

  LEFT JOIN hubs ph
         ON ph.id = o.pickup_hub_id

  LEFT JOIN hub_zone_map dhz
         ON dhz.hub_id = dh.id

  LEFT JOIN hub_zone_map phz
         ON phz.hub_id = ph.id

  WHERE
    o.business_id IN (290)

    -- Optional created_at filter
    -- AND o.created_at + INTERVAL '6 hours' >= TIMESTAMP '2025-10-01'
    -- AND o.created_at + INTERVAL '6 hours' <  TIMESTAMP '2025-11-01'
    -- AND COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours' >= TIMESTAMP '2025-10-01 00:00:00'
    -- AND COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours' <  TIMESTAMP '2025-11-01 00:00:00'
),

/* Attempt details:
   - order_runs.order_id = orders.id
   - order_runs.run_id = runs.id
   - eligible attempts: runs.run_type = 2 and order_runs.deleted_at IS NULL
*/
attempt_ranked AS (
  SELECT
    b.id AS order_id,

    orr.id AS order_run_id,
    orr.created_at AS attempt_at_utc,
    orr.created_at + INTERVAL '6 hours' AS attempt_at_bd,

    orr.order_run_status,

    CASE orr.order_run_status
      WHEN 1  THEN 'Pending'
      WHEN 2  THEN 'Delivered'
      WHEN 3  THEN 'Returned'
      WHEN 4  THEN 'Hold'
      WHEN 5  THEN 'Lost'
      WHEN 6  THEN 'Damage'
      WHEN 7  THEN 'Partial Delivery'
      WHEN 8  THEN 'Price Change'
      WHEN 9  THEN 'Paid Return'
      WHEN 10 THEN 'Exchage'
      WHEN 11 THEN 'Not Accepted'
      ELSE orr.order_run_status::text
    END AS attempt_status_name,

    ROW_NUMBER() OVER (
      PARTITION BY b.id
      ORDER BY orr.created_at ASC, orr.id ASC
    ) AS attempt_no

  FROM base b

  INNER JOIN order_runs orr
          ON orr.order_id = b.id
         AND orr.deleted_at IS NULL

  INNER JOIN runs r
          ON r.id = orr.run_id
         AND r.run_type = 2
),

/* Attempt pivot:
   only required fields added:
   - Attempt Count
   - 1st Attempt At
   - 1st Attempt Status
*/
attempt_pivot AS (
  SELECT
    ar.order_id,

    COUNT(*) AS attempt_count,

    MAX(ar.attempt_at_bd) FILTER (WHERE ar.attempt_no = 1) AS first_attempt_at_bd,
    MAX(ar.attempt_status_name) FILTER (WHERE ar.attempt_no = 1) AS first_attempt_status

  FROM attempt_ranked ar

  GROUP BY
    ar.order_id
),

/* Zone Transfer from order_logs */
zone_transfer_orders AS (
  SELECT DISTINCT
    ol.order_id
  FROM order_logs ol

  INNER JOIN base b
          ON b.id = ol.order_id

  WHERE
    ol.description ILIKE '%Zone transfer processed%'
),

/* Apply final calculations */
calc AS (
  SELECT
    b.*,

    CASE
      WHEN b.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,36,37,38,39,42,43)
        THEN 'Processing'
      WHEN b.transfer_status_id IN (15,17,18,21,22)
        THEN 'Terminal Status'
      WHEN b.transfer_status_id IN (19,20)
        THEN 'Terminal Status - Lost & Damage'
      ELSE 'Unknown'
    END AS order_status,

    CASE
      WHEN zto.order_id IS NOT NULL THEN 'Yes'
      ELSE 'No'
    END AS zone_transfer,

    COALESCE(ap.attempt_count, 0) AS attempt_count,

    ap.first_attempt_at_bd,
    ap.first_attempt_status,

    /* Final Fee logic */
    ROUND(
      CASE
        WHEN b.transfer_status_id = 17
          THEN (
            COALESCE(b.delivery_fee, 0)::numeric
            - COALESCE(b.discount, 0)::numeric
          ) / 100.0

        ELSE (
          COALESCE(b.delivery_fee, 0)::numeric
          + COALESCE(b.cod_fee, 0)::numeric
          - COALESCE(b.discount, 0)::numeric
        ) / 100.0
      END,
      2
    ) AS final_fee_tk,

    /* Sorted → LMH */
    ROUND(
      EXTRACT(EPOCH FROM (
        b.last_mile_at - b.aging_base_at
      )) / 3600,
      2
    ) AS sorted_to_lmh_hours,

    /* LMH → Terminal */
    ROUND(
      EXTRACT(EPOCH FROM (
        b.transfer_status_updated_at - b.last_mile_at
      )) / 3600,
      2
    ) AS lmh_to_terminal_hours_raw,

    /* Overall Aging Hours:
       - Terminal/Lost/Damage: transfer_status_updated_at - sorted_at
       - Processing/others: now - sorted_at
       - If sorted_at is blank, created_at is used
    */
    ROUND(
      EXTRACT(EPOCH FROM (
        CASE
          WHEN b.transfer_status_id IN (15,17,18,19,20,21,22)
            THEN b.transfer_status_updated_at
          ELSE NOW()
        END
        - b.aging_base_at
      )) / 3600,
      2
    ) AS overall_aging_hours

  FROM base b

  LEFT JOIN attempt_pivot ap
         ON ap.order_id = b.id

  LEFT JOIN zone_transfer_orders zto
         ON zto.order_id = b.id
)

SELECT
  /* Core order info */
  c.consignment_id                AS "Consignment ID",
  c.merchant_order_id             AS "Merchant Order ID",
  c.business_id                   AS "Business ID",
  c.recipient_name                AS "Recipient Name",
  c.recipient_phone               AS "Recipient Phone",

  c.transfer_status_name          AS "Transfer Status",

  c.zone_transfer                 AS "Zone Transfer",
  c.attempt_count                 AS "Attempt Count",
  c.first_attempt_at_bd           AS "1st Attempt At",
  c.first_attempt_status          AS "1st Attempt Status",

  c.transfer_status_updated_at + INTERVAL '6 hours' AS "Transfer Status Updated at",

  /* Reprocess at */
  c.reprocess_at + INTERVAL '6 hours' AS "Reprocess at",

  /* Money: paisa → taka */
  c.collectable_amount / 100.0               AS "Collectable Amount",
  c.collected_amount  / 100.0                AS "Collected Amount",
  ROUND(c.delivery_fee::numeric / 100.0, 2)  AS "Delivery Fee",
  ROUND(c.cod_fee::numeric      / 100.0, 2)  AS "COD Fee",
  c.discount / 100.0                         AS "Discount",

  /* Updated Final Fee */
  c.final_fee_tk                             AS "Final Fee",

  /* Hubs & zones */
  c.pickup_hub_name              AS "Pickup Hub",
  c.delivery_hub_name            AS "Delivery Hub",

  c.pickup_zone_type             AS "Pickup Zone",
  c.delivery_zone_type           AS "Delivery Zone",

  c.weight                       AS "Weight",

  c.aging_base_at + INTERVAL '6 hours' AS "Sorted at",
  c.created_at    + INTERVAL '6 hours' AS "Created at",
  c.last_mile_at  + INTERVAL '6 hours' AS "LMH at",

  /* Overall Aging */
  c.overall_aging_hours AS "Overall Aging (Hours)",

  /* Aging Bracket up to 240+ hours */
  CASE
    WHEN c.overall_aging_hours IS NULL THEN NULL
    WHEN c.overall_aging_hours < 24  THEN '24 hrs'
    WHEN c.overall_aging_hours < 48  THEN '48 hrs'
    WHEN c.overall_aging_hours < 72  THEN '72 hrs'
    WHEN c.overall_aging_hours < 96  THEN '96 hrs'
    WHEN c.overall_aging_hours < 120 THEN '120 hrs'
    WHEN c.overall_aging_hours < 144 THEN '144 hrs'
    WHEN c.overall_aging_hours < 168 THEN '168 hrs'
    WHEN c.overall_aging_hours < 192 THEN '192 hrs'
    WHEN c.overall_aging_hours < 216 THEN '216 hrs'
    WHEN c.overall_aging_hours < 240 THEN '240 hrs'
    ELSE '240 ++ hrs'
  END AS "Aging Bracket",

  /* Billing fields */
  c.billing_status_id AS "Billing Status ID",

  CASE
    WHEN COALESCE(c.billing_status_id, 0) = 0 THEN 'No Payment Yet'
    WHEN c.billing_status_id = 1 THEN 'Hub Payment Submitted'
    WHEN c.billing_status_id = 2 THEN 'Hub Payment Approved'
    WHEN c.billing_status_id = 3 THEN 'Invoice Unpaid'
    WHEN c.billing_status_id = 4 THEN 'Invoice Processing'
    WHEN c.billing_status_id = 5 THEN 'Invoice Paid'
  END AS "Billing Status Name",

  c.payment_invoice_id AS "Payment Invoice ID",

  c.billing_status_updated_at + INTERVAL '6 hours' AS "Billing Status Updated at"

FROM calc c

WHERE 1 = 1
  AND c.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,37,38,39
  )

-- Optional: filter by Order Status
-- AND c.order_status = 'Processing'

ORDER BY
  c.created_at DESC;
