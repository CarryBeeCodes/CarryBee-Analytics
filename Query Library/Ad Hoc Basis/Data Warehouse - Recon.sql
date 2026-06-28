```sql
SELECT
  consignment_id,
  MAX(timestamp_at) AS last_timestamp_at
FROM gold.mv_order_delivery_status
WHERE consignment_id IN ('F1220QGCJAG')
GROUP BY consignment_id
ORDER BY consignment_id;

```

Check MoM

```csharp
select
  date_trunc('month', sorted_at) as month,
  count(distinct consignment_id) as total_consignments
from orders
where sorted_at is not null
group by 1
order by 1;
```

Consignment type wise count

```sql
SELECT
    ts.name AS "Transfer Status Name",
    COUNT(*) FILTER (WHERE UPPER(LEFT(TRIM(o.consignment_id), 1)) = 'C') AS "C",
    COUNT(*) FILTER (WHERE UPPER(LEFT(TRIM(o.consignment_id), 1)) = 'E') AS "E",
    COUNT(*) FILTER (WHERE UPPER(LEFT(TRIM(o.consignment_id), 1)) = 'F') AS "F",
    COUNT(*) FILTER (WHERE UPPER(LEFT(TRIM(o.consignment_id), 1)) = 'R') AS "R"
FROM orders o
LEFT JOIN transfer_statuses ts
    ON o.transfer_status_id = ts.id
WHERE o.consignment_id IS NOT NULL
  AND TRIM(o.consignment_id) <> ''
GROUP BY ts.name
ORDER BY transfer_status_id;
```
