/* Orders detail with current status, hubs, zones & aging (UTC+6 timestamps)
   Amounts converted from paisa -> taka
   Return processing view for old_business_id = 14288
*/

WITH
/*----------------------------------------------------------
  1) Hub -> zone map by IDs
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      -- Dhaka ISD hubs (71 & 72 moved to Central Warehouse)
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214) THEN 'ISD'

      -- Central Warehouse
      WHEN h.id IN (71,72) THEN 'Central Warehouse'

      -- Central Inbound
      WHEN h.id IN (161) THEN 'Central Inbound'

      -- Sub Sort Zone hubs
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

/*----------------------------------------------------------
  2) Base orders + hubs + zones
----------------------------------------------------------*/
base AS (
  SELECT
    o.id,
    o.consignment_id,
    o.merchant_order_id,
    o.old_business_id,
    o.recipient_name,
    o.recipient_phone,
    o.transfer_status_id,
    o.transfer_status_updated_at,
    o.collectable_amount,
    o.collected_amount,
    o.delivery_fee,
    o.cod_fee,
    o.discount,
    o.pickup_hub_id,
    o.delivery_hub_id,
    o.weight,
    o.billing_status_id,
    o.payment_invoice_id,
    o.billing_status_updated_at,
    o.created_at,
    o.sorted_at,
    o.last_mile_at,

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
    ON dhz.hub_id = o.delivery_hub_id
  LEFT JOIN hub_zone_map phz
    ON phz.hub_id = o.pickup_hub_id
  WHERE
    o.old_business_id = 14288
    AND o.transfer_status_id IN (
      23,24,25,26,27,28,29,30,31,34,35,40,41,42,43,44,45,
      32,33
    )
    AND (o.created_at + INTERVAL '6 hours') >= TIMESTAMP '2025-03-01'
),

/*----------------------------------------------------------
  3) Aging logic
----------------------------------------------------------*/
calc AS (
  SELECT
    b.*,

    CASE
      WHEN b.transfer_status_id IN (23,24,25,26,27,28,29,30,31,34,35,40,41,42,43,44,45)
        THEN 'Processing'
      WHEN b.transfer_status_id IN (32,33)
        THEN 'Terminal Status'
      ELSE 'Unknown'
    END AS order_status,

    /* Sorted -> LMH */
    ROUND(
      EXTRACT(
        EPOCH FROM (
          (b.last_mile_at + INTERVAL '6 hours')
          - (b.sorted_at + INTERVAL '6 hours')
        )
      ) / 3600
    , 2) AS sorted_to_lmh_hours,

    /* LMH -> Terminal */
    ROUND(
      EXTRACT(
        EPOCH FROM (
          (b.transfer_status_updated_at + INTERVAL '6 hours')
          - (b.last_mile_at + INTERVAL '6 hours')
        )
      ) / 3600
    , 2) AS lmh_to_terminal_hours_raw,

    /* Overall Aging */
    CASE
      WHEN b.transfer_status_id IN (32,33) THEN
        ROUND(
          EXTRACT(
            EPOCH FROM (
              (b.transfer_status_updated_at + INTERVAL '6 hours')
              - (b.sorted_at + INTERVAL '6 hours')
            )
          ) / 3600
        , 2)

      WHEN b.transfer_status_id IN (23,24,25,26,27,28,29,30,31,34,35,40,41,42,43,44,45) THEN
        ROUND(
          EXTRACT(
            EPOCH FROM (
              (NOW() + INTERVAL '6 hours')
              - (b.sorted_at + INTERVAL '6 hours')
            )
          ) / 3600
        , 2)

      ELSE NULL
    END AS overall_aging_hours

  FROM base b
)

SELECT
  c.consignment_id AS "Consignment ID",
  c.merchant_order_id AS "Merchant Order ID",
  c.old_business_id AS "Business ID",
  c.recipient_name AS "Recipient Name",
  c.recipient_phone AS "Recipient Phone",

  c.transfer_status_name AS "Transfer Status",

  (c.transfer_status_updated_at + INTERVAL '6 hours') AS "Transfer Status Updated at",

  /* Money (paisa -> taka) */
  (c.collectable_amount / 100.0) AS "Collectable Amount",
  (c.collected_amount / 100.0) AS "Collected Amount",
  ROUND((c.delivery_fee::numeric / 100.0), 2) AS "Delivery Fee",
  ROUND((c.cod_fee::numeric / 100.0), 2) AS "COD Fee",
  (c.discount / 100.0) AS "Discount",

  /* Hubs & zones */
  c.pickup_hub_name AS "Pickup Hub",
  c.delivery_hub_name AS "Delivery Hub",
  c.pickup_zone_type AS "Pickup Zone",
  c.delivery_zone_type AS "Delivery Zone",

  c.weight AS "Weight",

  /* Direct orders timestamps in BDT */
  (c.created_at + INTERVAL '6 hours') AS "Created at",
  (c.sorted_at + INTERVAL '6 hours') AS "Sorted at",
  (c.last_mile_at + INTERVAL '6 hours') AS "LMH at",

  /* Final Overall Aging (Hours) */
  c.overall_aging_hours AS "Overall Aging (Hours)",

  CASE
    WHEN c.overall_aging_hours IS NULL THEN NULL
    WHEN c.overall_aging_hours < 24 THEN '24 hrs'
    WHEN c.overall_aging_hours < 48 THEN '48 hrs'
    WHEN c.overall_aging_hours < 72 THEN '72 hrs'
    WHEN c.overall_aging_hours < 96 THEN '96 hrs'
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
  (c.billing_status_updated_at + INTERVAL '6 hours') AS "Billing Status Updated at"

FROM calc c
ORDER BY c.created_at DESC;
