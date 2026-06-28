/* ============================================================
   WoW Pivot (weeks as COLUMNS) — Last 30 days (BD local)
   Rows: business_id
   Columns: 4 weeks ONLY (Week 4 is extended to include leftover days)
   Includes week date labels as columns so you know the exact timeframe.
   Time buckets in BD local time, filtered in UTC for index efficiency
   ============================================================ */

WITH
bounds AS (
  SELECT date_trunc('day', now() AT TIME ZONE 'Asia/Dhaka') AS today_start_local
),
range_bd AS (
  SELECT
    (today_start_local - INTERVAL '29 days') AS start_local,      -- inclusive
    (today_start_local + INTERVAL '1 day')  AS end_local_excl     -- exclusive (tomorrow 00:00)
  FROM bounds
),

/* 4 buckets:
   - Week 1..3 fixed 7 days
   - Week 4 = remaining days up to today (extended)
*/
periods AS (
  SELECT * FROM (VALUES
    (1, (SELECT start_local FROM range_bd),                         (SELECT start_local FROM range_bd) + INTERVAL '7 days'),
    (2, (SELECT start_local FROM range_bd) + INTERVAL '7 days',     (SELECT start_local FROM range_bd) + INTERVAL '14 days'),
    (3, (SELECT start_local FROM range_bd) + INTERVAL '14 days',    (SELECT start_local FROM range_bd) + INTERVAL '21 days'),
    (4, (SELECT start_local FROM range_bd) + INTERVAL '21 days',    (SELECT end_local_excl FROM range_bd))
  ) AS t(sort_key, start_local, end_local_excl)
),

periods_labeled AS (
  SELECT
    sort_key,
    start_local,
    end_local_excl,
    /* Example: "Jan 18–Jan 24" (end is exclusive, so show end-1day) */
    to_char(start_local::date, 'Mon DD') || '–' ||
    to_char((end_local_excl - INTERVAL '1 day')::date, 'Mon DD') AS week_label
  FROM periods
),

periods_utc AS (
  SELECT
    sort_key,
    week_label,
    start_local,
    end_local_excl,
    (start_local    - INTERVAL '6 hours') AS start_utc,
    (end_local_excl - INTERVAL '6 hours') AS end_utc_excl
  FROM periods_labeled
),

agg AS (
  SELECT
    o.business_id,
    p.sort_key,
    p.week_label,
    COUNT(DISTINCT o.consignment_id) AS processed_orders,
    ROUND(SUM(COALESCE(o.total_fee, 0)) / 100.0, 2) AS total_fee_tk,
    COUNT(DISTINCT (o.sorted_at + INTERVAL '6 hours')::date) AS active_days
  FROM periods_utc p
  JOIN public.orders o
    ON o.sorted_at >= p.start_utc
   AND o.sorted_at <  p.end_utc_excl
  WHERE o.sorted_at IS NOT NULL
    AND o.business_id IS NOT NULL
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
  GROUP BY o.business_id, p.sort_key, p.week_label
)

SELECT
  business_id AS "Business ID",

  /* Week labels (same for all businesses, repeated for convenience) */
  MAX(week_label) FILTER (WHERE sort_key=1) AS "Week 1 (BD) Range",
  MAX(week_label) FILTER (WHERE sort_key=2) AS "Week 2 (BD) Range",
  MAX(week_label) FILTER (WHERE sort_key=3) AS "Week 3 (BD) Range",
  MAX(week_label) FILTER (WHERE sort_key=4) AS "Week 4 (BD) Range (Extended)",

  /* Week 1 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=1), 0) AS "Week 1 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=1), 0) AS "Week 1 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=1), 0) AS "Week 1 Active Days",

  /* Week 2 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=2), 0) AS "Week 2 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=2), 0) AS "Week 2 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=2), 0) AS "Week 2 Active Days",

  /* Week 3 */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=3), 0) AS "Week 3 Orders",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=3), 0) AS "Week 3 Total Fee (Tk)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=3), 0) AS "Week 3 Active Days",

  /* Week 4 (extended) */
  COALESCE(MAX(processed_orders) FILTER (WHERE sort_key=4), 0) AS "Week 4 Orders (Extended)",
  COALESCE(MAX(total_fee_tk)     FILTER (WHERE sort_key=4), 0) AS "Week 4 Total Fee (Tk) (Extended)",
  COALESCE(MAX(active_days)      FILTER (WHERE sort_key=4), 0) AS "Week 4 Active Days (Extended)"

FROM agg
GROUP BY business_id
ORDER BY business_id;


