/* Weekly active merchants (1 Oct – 30 Nov)
Week 1 = 01–07 Oct, then every 7-day block from 01 Oct
*/

WITH base AS (
SELECT
(o.created_at + INTERVAL '6 hours')::date AS order_date,
o.business_id
FROM orders o
WHERE
(o.created_at + INTERVAL '6 hours')::date BETWEEN DATE '2025-10-01' AND DATE '2025-11-30'
AND o.transfer_status_id IN (
4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
35,36,37,38,39,42,43
)
),

weekly AS (
SELECT
-- Week number starting from 1 Oct (Week 1 = 1–7 Oct)
1 + ((order_date - DATE '2025-10-01') / 7) AS week_number,

```
-- Week start date (based on 1 Oct anchor)
(DATE '2025-10-01'
   + (((order_date - DATE '2025-10-01') / 7) * 7)
)::date AS week_start_date,

COUNT(DISTINCT business_id) AS active_merchants

```

FROM base
GROUP BY
1, 2
)

SELECT
week_number,
week_start_date,
(week_start_date + INTERVAL '6 days')::date AS week_end_date,
TO_CHAR(week_start_date, 'YYYY-MM')      AS month,
TO_CHAR(week_start_date, 'Mon')          AS month_name,
active_merchants
FROM weekly
ORDER BY week_number;
