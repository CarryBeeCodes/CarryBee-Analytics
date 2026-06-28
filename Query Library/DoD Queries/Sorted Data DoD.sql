/* Orders detail with current status, hubs, zones & UTC+6 timestamps
   Amounts converted from paisa → taka
*/

WITH
-- Hub → zone map by IDs (3PL kept as-is)
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145) THEN 'ISD'
      WHEN h.id IN (10) THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM hubs h
),

-- Base join with hubs, transfer status & zone types
base AS (
  SELECT
    o.*,
    ts.name          AS transfer_status_name,
    dh.name          AS delivery_hub_name,
    ph.name          AS pickup_hub_name,
    dhz.zone_type    AS delivery_zone_type,
    phz.zone_type    AS pickup_zone_type
  FROM orders o
  LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
  LEFT JOIN hubs dh              ON dh.id = o.delivery_hub_id
  LEFT JOIN hubs ph              ON ph.id = o.pickup_hub_id
  LEFT JOIN hub_zone_map dhz     ON dhz.hub_id = dh.id
  LEFT JOIN hub_zone_map phz     ON phz.hub_id = ph.id
  WHERE
    (o.sorted_at + INTERVAL '6 hours')
      BETWEEN TIMESTAMP '2026-01-03 15:00:00'
          AND TIMESTAMP '2026-01-04 07:00:00'
    AND o.transfer_status_id IN (
      4,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
    AND o.business_id != 10
)

SELECT
  -- Core order info
  b.consignment_id                      AS "Consignment ID",
  b.business_id                         AS "Business ID",
  b.transfer_status_name                AS "Transfer Status",

  (b.transfer_status_updated_at + INTERVAL '6 hours') AS "Transfer Status Updated at",

  -- Money (paisa → taka)
  (b.collectable_amount / 100.0)                    AS "Collectable Amount",
  (b.collected_amount  / 100.0)                     AS "Collected Amount",
  ROUND((b.delivery_fee::numeric / 100.0), 2)       AS "Delivery Fee",
  ROUND((b.cod_fee::numeric      / 100.0), 2)       AS "COD Fee",
  (b.discount / 100.0)                              AS "Discount",

  -- Hubs & zones
  b.pickup_hub_name                    AS "Pickup Hub",
  b.delivery_hub_name                  AS "Delivery Hub",
  b.pickup_zone_type                   AS "Pickup Zone",
  b.delivery_zone_type                 AS "Delivery Zone",

  -- Other order info
  b.weight                             AS "Weight",
  (b.sorted_at    + INTERVAL '6 hours') AS "Sorted at",
  (b.created_at   + INTERVAL '6 hours') AS "Created at",
  (b.last_mile_at + INTERVAL '6 hours') AS "LMH at",

  -- Billing fields
  b.billing_status_id                  AS "Billing Status ID",
  CASE
    WHEN COALESCE(b.billing_status_id, 0) = 0 THEN 'No Payment Yet'
    WHEN b.billing_status_id = 1 THEN 'Hub Payment Submitted'
    WHEN b.billing_status_id = 2 THEN 'Hub Payment Approved'
    WHEN b.billing_status_id = 3 THEN 'Invoice Unpaid'
    WHEN b.billing_status_id = 4 THEN 'Invoice Processing'
    WHEN b.billing_status_id = 5 THEN 'Invoice Paid'
  END                                  AS "Billing Status Name"

  --b.payment_invoice_id                 AS "Payment Invoice ID",
  --b.billing_status_updated_at          AS "Billing Status Updated at"

FROM base b
ORDER BY b.sorted_at DESC;
