SELECT
  oi.business_id,
  oi.business_name,
  ROUND(SUM(oi.collected_amount) / 100.0, 2) AS collected_amount,
  ROUND(SUM(oi.total_fee)        / 100.0, 2) AS fee,
  ROUND(SUM(oi.amount)           / 100.0, 2) AS payable
FROM order_invoices oi
--LEFT JOIN payment_invoices pi
  --ON pi.id = oi.payment_invoice_id
WHERE
  oi.hub_payout_status = 2
  AND oi.payment_status = 0
GROUP BY
  oi.business_id,
  oi.business_name
ORDER BY
  oi.business_id;
