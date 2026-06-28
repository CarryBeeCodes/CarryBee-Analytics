SELECT
    business_id,
    MAX(sorted_at + INTERVAL '6 hours') AS last_order_date
FROM orders
WHERE transfer_status_id IN (
    4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39
)
AND business_id IN ( )
GROUP BY business_id;
