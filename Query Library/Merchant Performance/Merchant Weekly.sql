/* ============================================================
   WoW Pivot (weeks as COLUMNS)
   Rows: business_id only
   Metrics per period: processed_orders, total_fee_tk, active_days
   Time buckets in BD local time, filtered in UTC for index efficiency
   ============================================================ */

WITH
params AS (
  SELECT
    /* ✅ Put business IDs here. Leave empty ARRAY[]::int[] for ALL businesses */
    ARRAY[]::int[] AS business_ids
),

periods AS (
  SELECT * FROM (VALUES
    /* December 2025 */
    (1, 'Dec 01–07',       TIMESTAMP '2025-12-01 00:00:00', TIMESTAMP '2025-12-08 00:00:00'),
    (2, 'Dec 08–14',       TIMESTAMP '2025-12-08 00:00:00', TIMESTAMP '2025-12-15 00:00:00'),
    (3, 'Dec 15–21',       TIMESTAMP '2025-12-15 00:00:00', TIMESTAMP '2025-12-22 00:00:00'),
    (4, 'Dec 22–31',       TIMESTAMP '2025-12-22 00:00:00', TIMESTAMP '2026-01-01 00:00:00'),
    (5, 'December Total',  TIMESTAMP '2025-12-01 00:00:00', TIMESTAMP '2026-01-01 00:00:00'),

    /* January 2026 */
    (6, 'Jan 01–07',       TIMESTAMP '2026-01-01 00:00:00', TIMESTAMP '2026-01-08 00:00:00'),
    (7, 'Jan 08–15',       TIMESTAMP '2026-01-08 00:00:00', TIMESTAMP '2026-01-16 00:00:00'),
    (8, 'Jan 01–15 Total', TIMESTAMP '2026-01-01 00:00:00', TIMESTAMP '2026-01-16 00:00:00'),
    (9, 'Jan 16–25',       TIMESTAMP '2026-01-16 00:00:00', TIMESTAMP '2026-01-26 00:00:00')
  ) AS t(sort_key, period_label, start_local, end_local_excl)
),

periods_utc AS (
  SELECT
    sort_key,
    period_label,
    (start_local - INTERVAL '6 hours') AS start_utc,
    (end_local_excl - INTERVAL '6 hours') AS end_utc_excl
  FROM periods
),

agg AS (
  SELECT
    o.business_id,
    p.sort_key,
    p.period_label,

    COUNT(DISTINCT o.consignment_id) AS processed_orders,
    ROUND(SUM(COALESCE(o.total_fee, 0)) / 100.0, 2) AS total_fee_tk,
    COUNT(DISTINCT (o.sorted_at + INTERVAL '6 hours')::date) AS active_days

  FROM periods_utc p
  JOIN public.orders o
    ON o.sorted_at >= p.start_utc
   AND o.sorted_at <  p.end_utc_excl
  CROSS JOIN params prm
  WHERE o.sorted_at IS NOT NULL
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
    AND (
      COALESCE(array_length(prm.business_ids, 1), 0) = 0
      OR o.business_id = ANY (prm.business_ids)
    )
  GROUP BY o.business_id, p.sort_key, p.period_label
)

SELECT
  business_id AS "Business ID",

  /* Dec 01–07 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=1), 0) AS "Dec 01–07 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=1), 0) AS "Dec 01–07 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=1), 0) AS "Dec 01–07 Active Days",

  /* Dec 08–14 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=2), 0) AS "Dec 08–14 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=2), 0) AS "Dec 08–14 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=2), 0) AS "Dec 08–14 Active Days",

  /* Dec 15–21 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=3), 0) AS "Dec 15–21 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=3), 0) AS "Dec 15–21 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=3), 0) AS "Dec 15–21 Active Days",

  /* Dec 22–31 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=4), 0) AS "Dec 22–31 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=4), 0) AS "Dec 22–31 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=4), 0) AS "Dec 22–31 Active Days",

  /* December Total */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=5), 0) AS "December Total Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=5), 0) AS "December Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=5), 0) AS "December Total Active Days",

  /* Jan 01–07 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=6), 0) AS "Jan 01–07 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=6), 0) AS "Jan 01–07 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=6), 0) AS "Jan 01–07 Active Days",

  /* Jan 08–15 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=7), 0) AS "Jan 08–15 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=7), 0) AS "Jan 08–15 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=7), 0) AS "Jan 08–15 Active Days",

  /* Jan 01–15 Total */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=8), 0) AS "Jan 01–15 Total Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=8), 0) AS "Jan 01–15 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=8), 0) AS "Jan 01–15 Total Active Days",

  /* Jan 16–25 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=9), 0) AS "Jan 16–25 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=9), 0) AS "Jan 16–25 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=9), 0) AS "Jan 16–25 Active Days"

FROM agg
GROUP BY business_id
ORDER BY business_id;
