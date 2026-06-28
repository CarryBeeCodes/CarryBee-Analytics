/* ============================================================
   Sorted Date Wise Processed Orders + Revenue
   Business day logic: 6:00 AM BD -> next day 6:00 AM BD

   Example:
   - 05 Feb sorted date = 05 Feb 06:00 BD to 06 Feb 06:00 BD
   - 06 Feb sorted date = 06 Feb 06:00 BD to 07 Feb 06:00 BD

   DATE FILTER:
   - Set start_date and end_date below
   - Both are inclusive business dates
   ============================================================ */

WITH settings AS (
  SELECT
    DATE '2025-03-01' AS start_date,   -- inclusive
    DATE '2026-03-09' AS end_date      -- inclusive
),

params AS (
  SELECT
    start_date,
    end_date,

    /* 6 AM BD to 6 AM BD == 00:00 UTC to 00:00 UTC */
    start_date::timestamp      AS start_utc,
    (end_date + 1)::timestamp  AS end_utc_excl
  FROM settings
),

base AS (
  SELECT
    o.consignment_id,
    o.transfer_status_id,

    /* Sorted date bucket: 6 AM BD -> next 6 AM BD */
    o.sorted_at::date AS sorted_bd_date,

    /* Revenue in taka */
    CASE
      WHEN o.transfer_status_id IN (17, 32) THEN
        (
          COALESCE(o.delivery_fee, 0)::numeric / 100.0
          - COALESCE(o.discount, 0)::numeric / 100.0
        )
      ELSE
        (
          COALESCE(o.delivery_fee, 0)::numeric / 100.0
          + COALESCE(o.cod_fee, 0)::numeric / 100.0
          - COALESCE(o.discount, 0)::numeric / 100.0
        )
    END AS revenue_tk
  FROM public.orders o
  JOIN params p ON TRUE
  WHERE o.sorted_at IS NOT NULL
    AND o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc_excl
    AND o.business_id <> 10
    AND o.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,32,35,38,39
    )
)

SELECT
  sorted_bd_date                         AS "Sorted Date",
  TO_CHAR(sorted_bd_date, 'DD Mon YYYY') AS "Date",
  COUNT(DISTINCT consignment_id)         AS "Processed Orders",
  ROUND(SUM(revenue_tk), 2)              AS "Revenue"
FROM base
GROUP BY sorted_bd_date
ORDER BY sorted_bd_date;
