/* ============================================================
   Central Warehouse DoD Performance – Daily Summary (with CW=0, refined)
   - Row = Order Date (sorted_at + 6h :: date)
   - Status set (ORDERS table, current status):
       11,12,13,14,15,16,17,18,19,20,21,22,
       35,36,37,38,39,42,43

   Exclusion logic for CW:
     EXCLUDE orders where:
       - cw_count = 0 (no status 11 in order_logs)
       - AND has any status in (36,37,38,39) in order_logs
     => they never go through CW, purely special-flow.

   Metrics per day (after exclusion):
     1) Total Orders (status set, CW-relevant only)
     2) Processed 3 pm - 12 am
     3) Processed 12 am to 7 am (next day, but shown on same row)
     4) Orders Left Central Warehouse
     5) Orders with CW→LMH segment (cw_to_lmh_hours > 0)
     6) Orders with CW Count = 0
     7) Avg CW Processing Time (hrs, only >0)
     8) Last 7 days avg processing time (rolling on daily avg)
     9) Main aging buckets + % (on orders_with_valid_cw_lmh)
    10) Extended 24-hr buckets from 48+ (counts only)

   Time-window columns (independent from CW logic, but same status set):
     - "Processed 3 pm - 12 am"
         = count of orders with (sorted_at + 6h) between
           [order_date 15:00, order_date 24:00)
     - "Processed 12 am to 7 am"
         = count of orders with (sorted_at + 6h) between
           [order_date+1 day 00:00, order_date+1 day 07:00)
============================================================ */

WITH
/*----------------------------------------------------------
  1) Base orders (date + status filter, using sorted_at)
----------------------------------------------------------*/
base AS (
  SELECT
    o.id AS order_id,
    o.transfer_status_id,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date
  FROM public.orders o
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-01 00:00:00'

    /* CW-related statuses (ORDERS table) */
    AND o.transfer_status_id IN (
      11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
),

/*----------------------------------------------------------
  2) Per-order CW & OTW LMH timestamps + CW counters from logs
----------------------------------------------------------*/
flow AS (
  SELECT
    b.order_id,
    b.order_date,
    b.transfer_status_id,
    cw_stats.first_cw_at_raw,
    cw_stats.cw_count,
    cw_stats.has_status_36_39,
    otw_lmh.on_way_lmh_raw,

    /* CW → LMH (hrs); raw numeric, may be NULL or <=0 */
    CASE
      WHEN cw_stats.first_cw_at_raw IS NOT NULL
       AND otw_lmh.on_way_lmh_raw IS NOT NULL
      THEN EXTRACT(
             EPOCH FROM (otw_lmh.on_way_lmh_raw - cw_stats.first_cw_at_raw)
           ) / 3600.0
    END AS cw_to_lmh_hours
  FROM base b

  /* CW stats from order_logs: first 11, count(11), and any 36/37/38/39 */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status = 11 THEN ol.created_at END)
        AS first_cw_at_raw,
      COUNT(*) FILTER (WHERE ol.current_status = 11)
        AS cw_count,
      BOOL_OR(ol.current_status IN (36,37,38,39))
        AS has_status_36_39
    FROM public.order_logs ol
    WHERE ol.order_id = b.order_id
  ) cw_stats ON TRUE

  /* On the way to Last Mile Hub: status 12, else 35 with hub_id = 71 */
  LEFT JOIN LATERAL (
    SELECT
      ol.created_at AS on_way_lmh_raw
    FROM public.order_logs ol
    WHERE ol.order_id = b.order_id
      AND (ol.current_status = 12 OR (ol.current_status = 35 AND ol.hub_id = 71))
    ORDER BY
      CASE WHEN ol.current_status = 12 THEN 1 ELSE 2 END,
      ol.created_at,
      ol.id
    LIMIT 1
  ) otw_lmh ON TRUE
),

/*----------------------------------------------------------
  3) Daily aggregation – AFTER excluding "never CW but 36–39" flows
----------------------------------------------------------*/
aggregated AS (
  SELECT
    f.order_date,

    /* 1) CW-relevant orders:
          - in status set
          - NOT (cw_count = 0 AND has_status_36_39 = TRUE) */
    COUNT(*) AS total_orders,

    /* 2) Orders that have left Central Warehouse (current status 12+) */
    COUNT(*) FILTER (
      WHERE f.transfer_status_id IN (
        12,13,14,15,16,17,18,19,20,21,22,
        35,36,37,38,39,42,43
      )
    ) AS orders_left_cw,

    /* 3) Orders that actually have a positive CW→LMH duration */
    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 0
    ) AS orders_with_valid_cw_lmh,

    /* 4) Orders whose CW count = 0 (no status 11 in logs),
          but they are still CW-relevant
          (we already excluded "no 11 AND has 36–39" below) */
    COUNT(*) FILTER (
      WHERE COALESCE(f.cw_count, 0) = 0
    ) AS orders_cw_count_0,

    /* 5) Avg CW Processing Time – only >0 */
    AVG(
      CASE
        WHEN f.cw_to_lmh_hours > 0 THEN f.cw_to_lmh_hours
      END
    ) AS avg_cw_processing_hours,

    /* Aging buckets on cw_to_lmh_hours >0; sum = orders_with_valid_cw_lmh */

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 0 AND f.cw_to_lmh_hours <= 3
    ) AS cnt_0_3,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 3 AND f.cw_to_lmh_hours <= 6
    ) AS cnt_3_6,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 6 AND f.cw_to_lmh_hours <= 9
    ) AS cnt_6_9,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 9 AND f.cw_to_lmh_hours <= 12
    ) AS cnt_9_12,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 12 AND f.cw_to_lmh_hours <= 24
    ) AS cnt_12_24,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 24 AND f.cw_to_lmh_hours <= 36
    ) AS cnt_24_36,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 36 AND f.cw_to_lmh_hours <= 48
    ) AS cnt_36_48,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 48 AND f.cw_to_lmh_hours <= 72
    ) AS cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 72 AND f.cw_to_lmh_hours <= 96
    ) AS cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 96 AND f.cw_to_lmh_hours <= 120
    ) AS cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 120 AND f.cw_to_lmh_hours <= 144
    ) AS cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 144 AND f.cw_to_lmh_hours <= 168
    ) AS cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 168 AND f.cw_to_lmh_hours <= 192
    ) AS cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 192 AND f.cw_to_lmh_hours <= 216
    ) AS cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 216 AND f.cw_to_lmh_hours <= 240
    ) AS cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 240 AND f.cw_to_lmh_hours <= 264
    ) AS cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 264 AND f.cw_to_lmh_hours <= 288
    ) AS cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 288 AND f.cw_to_lmh_hours <= 312
    ) AS cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 312 AND f.cw_to_lmh_hours <= 336
    ) AS cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 336 AND f.cw_to_lmh_hours <= 360
    ) AS cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 360 AND f.cw_to_lmh_hours <= 384
    ) AS cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 384 AND f.cw_to_lmh_hours <= 408
    ) AS cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 408 AND f.cw_to_lmh_hours <= 432
    ) AS cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 432 AND f.cw_to_lmh_hours <= 456
    ) AS cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 456 AND f.cw_to_lmh_hours <= 480
    ) AS cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.cw_to_lmh_hours > 480
    ) AS cnt_480_plus
  FROM flow f
  WHERE NOT (
    COALESCE(f.cw_count, 0) = 0
    AND COALESCE(f.has_status_36_39, FALSE) = TRUE
  )
  GROUP BY f.order_date
),

/*----------------------------------------------------------
  4) Time buckets for independent volume metrics
     - Based only on ORDERS (same filters as base),
       NOT on CW exclusion logic.
----------------------------------------------------------*/
time_buckets AS (
  SELECT
    (o.sorted_at + INTERVAL '6 hours')::date AS local_date,
    CASE
      WHEN (o.sorted_at + INTERVAL '6 hours')::time >= TIME '15:00:00'
           THEN '3pm_12am'
      WHEN (o.sorted_at + INTERVAL '6 hours')::time <  TIME '07:00:00'
           THEN '12am_7am'
      ELSE 'other'
    END AS bucket,
    COUNT(*) AS cnt
  FROM public.orders o
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-01 00:00:00'
    AND o.transfer_status_id IN (
      11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
  GROUP BY
    (o.sorted_at + INTERVAL '6 hours')::date,
    CASE
      WHEN (o.sorted_at + INTERVAL '6 hours')::time >= TIME '15:00:00'
           THEN '3pm_12am'
      WHEN (o.sorted_at + INTERVAL '6 hours')::time <  TIME '07:00:00'
           THEN '12am_7am'
      ELSE 'other'
    END
)

/*----------------------------------------------------------
  5) Final select: add time-window columns right after Total Orders
----------------------------------------------------------*/
SELECT
  a.order_date AS "Order Date",

  a.total_orders AS "Total Orders",

  /* independent volume metrics by DoD window (same status set) */
  COALESCE(tb1.cnt, 0) AS "Processed 3 pm - 12 am",
  COALESCE(tb2.cnt, 0) AS "Processed 12 am to 7 am",

  a.orders_left_cw           AS "Orders Left CW",
  a.orders_with_valid_cw_lmh AS "Orders with CW to LMH segment",
  a.orders_cw_count_0        AS "Orders with CW Count = 0",

  ROUND(a.avg_cw_processing_hours, 2)
    AS "Avg CW Processing Time (hrs)",

  /* Rolling 7 previous reporting days on the daily avg */
  ROUND(
    AVG(a.avg_cw_processing_hours) OVER (
      ORDER BY a.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ),
    2
  ) AS "Last 7 days avg processing time",

  /* === Main aging buckets – counts === */
  a.cnt_0_3     AS "3 hrs",       -- 0–3 hrs
  a.cnt_3_6     AS "6 hrs",       -- >3–6 hrs
  a.cnt_6_9     AS "9 hrs",       -- >6–9 hrs
  a.cnt_9_12    AS "12 hrs",      -- >9–12 hrs
  a.cnt_12_24   AS "24 hrs",      -- >12–24 hrs
  (
    a.cnt_24_36
    + a.cnt_36_48
    + a.cnt_48_72
    + a.cnt_72_96
    + a.cnt_96_120
    + a.cnt_120_144
    + a.cnt_144_168
    + a.cnt_168_192
    + a.cnt_192_216
    + a.cnt_216_240
    + a.cnt_240_264
    + a.cnt_264_288
    + a.cnt_288_312
    + a.cnt_312_336
    + a.cnt_336_360
    + a.cnt_360_384
    + a.cnt_384_408
    + a.cnt_408_432
    + a.cnt_432_456
    + a.cnt_456_480
    + a.cnt_480_plus
  )           AS "24 hrs++",    -- >24 hrs

  /* === Main aging buckets – FRACTION of orders_with_valid_cw_lmh (no *100) === */
  ROUND(
    a.cnt_0_3::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 3 hrs",

  ROUND(
    a.cnt_3_6::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 6 hrs",

  ROUND(
    a.cnt_6_9::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 9 hrs",

  ROUND(
    a.cnt_9_12::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 12 hrs",

  ROUND(
    a.cnt_12_24::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 24 hrs",

  ROUND(
    (
      a.cnt_24_36
      + a.cnt_36_48
      + a.cnt_48_72
      + a.cnt_72_96
      + a.cnt_96_120
      + a.cnt_120_144
      + a.cnt_144_168
      + a.cnt_168_192
      + a.cnt_192_216
      + a.cnt_216_240
      + a.cnt_240_264
      + a.cnt_264_288
      + a.cnt_288_312
      + a.cnt_312_336
      + a.cnt_336_360
      + a.cnt_360_384
      + a.cnt_384_408
      + a.cnt_408_432
      + a.cnt_432_456
      + a.cnt_456_480
      + a.cnt_480_plus
    )::numeric /
    NULLIF(a.orders_with_valid_cw_lmh, 0),
    2
  ) AS "% 24 hrs++",

  /* === Extended aging buckets (counts only) === */
  a.cnt_48_72    AS "48 hrs",     -- >48–72 hrs
  a.cnt_72_96    AS "72 hrs",     -- >72–96 hrs
  a.cnt_96_120   AS "96 hrs",     -- >96–120 hrs
  a.cnt_120_144  AS "120 hrs",    -- >120–144 hrs
  a.cnt_144_168  AS "144 hrs",    -- >144–168 hrs
  a.cnt_168_192  AS "168 hrs",    -- >168–192 hrs
  a.cnt_192_216  AS "192 hrs",    -- >192–216 hrs
  a.cnt_216_240  AS "216 hrs",    -- >216–240 hrs
  a.cnt_240_264  AS "240 hrs",    -- >240–264 hrs
  a.cnt_264_288  AS "264 hrs",    -- >264–288 hrs
  a.cnt_288_312  AS "288 hrs",    -- >288–312 hrs
  a.cnt_312_336  AS "312 hrs",    -- >312–336 hrs
  a.cnt_336_360  AS "336 hrs",    -- >336–360 hrs
  a.cnt_360_384  AS "360 hrs",    -- >360–384 hrs
  a.cnt_384_408  AS "384 hrs",    -- >384–408 hrs
  a.cnt_408_432  AS "408 hrs",    -- >408–432 hrs
  a.cnt_432_456  AS "432 hrs",    -- >432–456 hrs
  a.cnt_456_480  AS "456 hrs",    -- >456–480 hrs
  a.cnt_480_plus AS "480 hrs++"   -- >480 hrs

FROM aggregated a
LEFT JOIN time_buckets tb1
  ON tb1.local_date = a.order_date
 AND tb1.bucket     = '3pm_12am'
LEFT JOIN time_buckets tb2
  ON tb2.local_date = a.order_date + INTERVAL '1 day'
 AND tb2.bucket     = '12am_7am'
ORDER BY a.order_date DESC;
