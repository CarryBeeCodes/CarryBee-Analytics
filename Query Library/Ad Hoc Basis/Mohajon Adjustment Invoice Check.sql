SELECT
  oi.business_id,
  oi.business_name,
  oi.consignment_id,
  oi.invoice_type,
  ROUND((oi.total_fee / 100.0), 2) AS fee,
  ROUND((oi.amount / 100.0), 2)    AS payable,
  oi.updated_at + INTERVAL '6 hours' AS updated,
  pi.invoice_id
FROM order_invoices oi
LEFT JOIN payment_invoices pi
  ON pi.id = oi.payment_invoice_id
WHERE oi.invoice_type IN ('adjustment')
  AND oi.consignment_id IN ('F0109PWF23K','ff')
ORDER BY oi.business_id;
