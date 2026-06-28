/* ============================================================
   Business-wise Processed Orders + RVN by Custom Month (21 -> 20 cycle, UTC+6 view)

   Custom month mapping:
   - 2025-02-21 to 2025-03-20  => Mar 25
   - 2025-03-21 to 2025-04-20  => Apr 25
   - ...
   - 2026-02-21 to 2026-03-20  => Mar 26
   - 2026-03-21 to 2026-04-20  => Apr 26

   Column sequence:
   Business ID | 1st Order Date | Total Processed Orders | Lifetime RVN
   | month-wise processed columns
   | month-wise RVN columns
   ============================================================ */

WITH params AS (
  SELECT
    TIMESTAMP '2025-02-21 00:00:00' AS start_local,
    TIMESTAMP '2026-04-21 00:00:00' AS end_local_excl,
    (TIMESTAMP '2025-02-21 00:00:00' - INTERVAL '6 hours') AS start_utc,
    (TIMESTAMP '2026-04-21 00:00:00' - INTERVAL '6 hours') AS end_utc_excl
),

biz AS (
  /* Put business IDs inside the array below */
  SELECT DISTINCT unnest(ARRAY[
    /* 169, 212, 321 */
  ]::int[]) AS business_id
),

base AS (
  SELECT
    o.business_id,
    o.consignment_id,
    o.transfer_status_id,
    COALESCE(o.delivery_fee, 0) AS delivery_fee,
    COALESCE(o.cod_fee, 0) AS cod_fee,
    COALESCE(o.discount, 0) AS discount,
    (o.sorted_at + INTERVAL '6 hours') AS sorted_at_local,

    /* Shift by +11 days so 21->20 cycle maps to target month name */
    date_trunc('month', (o.sorted_at + INTERVAL '6 hours') + INTERVAL '11 days')::date AS custom_month_start

  FROM public.orders o
  JOIN biz b
    ON b.business_id = o.business_id
  JOIN params p
    ON TRUE
  WHERE o.sorted_at IS NOT NULL
    AND o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc_excl
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,37,38,39)
),

calc AS (
  SELECT
    b.business_id,
    b.consignment_id,
    b.sorted_at_local,
    b.custom_month_start,

    CASE
      WHEN b.transfer_status_id = 17
        THEN (b.delivery_fee - b.discount)
      ELSE (b.delivery_fee + b.cod_fee - b.discount)
    END AS revenue_paisa
  FROM base b
)

SELECT
  bz.business_id AS "Business ID",

  MIN(c.sorted_at_local) AS "1st Order Date",

  COALESCE(COUNT(DISTINCT c.consignment_id), 0) AS "Total Processed Orders",

  ROUND(COALESCE(SUM(c.revenue_paisa), 0) / 100.0, 2) AS "Lifetime RVN",

  /* =========================
     Month-wise Processed Orders
     ========================= */
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-03-01'), 0) AS "Mar 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-04-01'), 0) AS "Apr 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-05-01'), 0) AS "May 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-06-01'), 0) AS "Jun 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-07-01'), 0) AS "Jul 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-08-01'), 0) AS "Aug 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-09-01'), 0) AS "Sep 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-10-01'), 0) AS "Oct 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-11-01'), 0) AS "Nov 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2025-12-01'), 0) AS "Dec 25",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2026-01-01'), 0) AS "Jan 26",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2026-02-01'), 0) AS "Feb 26",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2026-03-01'), 0) AS "Mar 26",
  COALESCE(COUNT(DISTINCT c.consignment_id) FILTER (WHERE c.custom_month_start = DATE '2026-04-01'), 0) AS "Apr 26",

  /* =========================
     Month-wise RVN
     ========================= */
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-03-01'), 0) / 100.0, 2) AS "Mar 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-04-01'), 0) / 100.0, 2) AS "Apr 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-05-01'), 0) / 100.0, 2) AS "May 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-06-01'), 0) / 100.0, 2) AS "Jun 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-07-01'), 0) / 100.0, 2) AS "Jul 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-08-01'), 0) / 100.0, 2) AS "Aug 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-09-01'), 0) / 100.0, 2) AS "Sep 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-10-01'), 0) / 100.0, 2) AS "Oct 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-11-01'), 0) / 100.0, 2) AS "Nov 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2025-12-01'), 0) / 100.0, 2) AS "Dec 25 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2026-01-01'), 0) / 100.0, 2) AS "Jan 26 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2026-02-01'), 0) / 100.0, 2) AS "Feb 26 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2026-03-01'), 0) / 100.0, 2) AS "Mar 26 RVN",
  ROUND(COALESCE(SUM(c.revenue_paisa) FILTER (WHERE c.custom_month_start = DATE '2026-04-01'), 0) / 100.0, 2) AS "Apr 26 RVN"

FROM biz bz
LEFT JOIN calc c
  ON bz.business_id = c.business_id
GROUP BY bz.business_id
ORDER BY bz.business_id;
