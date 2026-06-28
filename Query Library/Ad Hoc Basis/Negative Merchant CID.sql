SELECT
  (oi.delivered_at + INTERVAL '6 hours') AS "Delivery/Return Date",
  oi.business_id,
  oi.business_name,
  oi.consignment_id AS "CID",
  oi.order_status   AS "Last Status",
  oi.invoice_type,

  (oi.meta ->> 'weight')::int AS "Weight",

  ROUND(oi.collected_amount / 100.0, 2) AS "Collected Amount",

  ROUND(COALESCE((oi.meta ->> 'delivery_fee')::numeric, 0) / 100.0, 2) AS "Delivery Fee",
  ROUND(COALESCE((oi.meta ->> 'cash_on_delivery_fee')::numeric, 0) / 100.0, 2) AS "COD Fee",
  ROUND(COALESCE((oi.meta ->> 'discount')::numeric, 0) / 100.0, 2) AS "Discount",

  ROUND(oi.total_fee / 100.0, 2) AS "Final Fee",
  ROUND(oi.amount    / 100.0, 2) AS "Billing Amount",

  (oi.updated_at + INTERVAL '6 hours') AS "Billing_status_updated_at",
  pi.invoice_id
FROM order_invoices oi
LEFT JOIN payment_invoices pi
  ON pi.id = oi.payment_invoice_id
WHERE
  oi.business_id IN (7446,)
    
  AND oi.hub_payout_status = 2
  AND oi.payment_status = 0
ORDER BY
  oi.business_id,
  oi.consignment_id;
