/* WoW model (LOCAL = UTC+6)
   - Week 1 anchored at 2026-01-01 (Jan 1–7)
   - Rows per week: 5 distance rows + 2 extra rows:
       1) Weight Slab wise Total
       2) Contribution %  (FRACTION, NOT *100)
   - 0-200 segmented columns: 0-1, 1-10, 10-50, 50-100, 100-200
     * In TOTAL row: segmented columns are true sums (e.g., SUM of 0-1)
     * In Contribution% row: segmented columns are (segment_total / total_0_200)
   - Distance wise Total / Distance Contribution %:
     * based on MAIN slabs only (0-200, 201-500, ... , 3000+)
     * segmented columns do NOT affect these calculations
   - Slabs: up to 2501-3000, then 3000+
*/

WITH params AS (
  SELECT
    /* >>> set these in LOCAL time (UTC+6) <<< */
    TIMESTAMP '2026-01-01 00:00:00' AS anchor_local,  -- Week 1 starts here
    TIMESTAMP '2026-01-01 00:00:00' AS start_local,
    TIMESTAMP '2026-02-10 00:00:00' AS end_local
),
const AS (
  SELECT
    p.anchor_local::date AS week0_date,
    INTERVAL '6 hours'   AS tz_offset
  FROM params p
),
week_bounds AS (
  SELECT
    (c.week0_date + 7 * ((p.start_local::date - c.week0_date) / 7))::date AS first_week_start_date,
    (c.week0_date + 7 * (((p.end_local - INTERVAL '1 second')::date - c.week0_date) / 7))::date AS last_week_start_date
  FROM params p
  CROSS JOIN const c
),
weeks AS (
  SELECT
    gs::date AS week_start_date,
    ((gs::date - c.week0_date) / 7 + 1) AS week,
    (to_char(gs::date, 'DD Mon YYYY') || ' - ' || to_char(gs::date + 6, 'DD Mon YYYY')) AS "Start & End Date"
  FROM week_bounds wb
  CROSS JOIN const c
  CROSS JOIN LATERAL generate_series(
    wb.first_week_start_date::timestamp,
    wb.last_week_start_date::timestamp,
    INTERVAL '7 days'
  ) gs
),
distance_types AS (
  SELECT *
  FROM (VALUES
    (1, 1, 'Same City'),
    (2, 2, 'ISD to Sub'),
    (3, 3, 'ISD to OSD'),
    (4, 4, 'OSD to ISD'),
    (5, 5, 'OSD to OSD')
  ) v(distance_type, sort_order, distance_type_name)
),
orders_base AS (
  SELECT
    o.consignment_id,
    dt.distance_type_name,
    dt.sort_order,
    o.weight,
    (o.sorted_at + c.tz_offset)::timestamp AS sorted_at_local,

    /* week bucket based on LOCAL date, anchored at params.anchor_local */
    ((( (o.sorted_at + c.tz_offset)::date - c.week0_date) / 7) + 1) AS week,
    (c.week0_date + 7 * ((( (o.sorted_at + c.tz_offset)::date - c.week0_date) / 7)))::date AS week_start_date
  FROM orders o
  CROSS JOIN params p
  CROSS JOIN const c
  JOIN distance_types dt
    ON dt.distance_type = o.distance_type
  WHERE o.sorted_at IS NOT NULL
    /* index-friendly UTC bounds derived from local window (UTC+6) */
    AND o.sorted_at >= (p.start_local - c.tz_offset)
    AND o.sorted_at <  (p.end_local   - c.tz_offset)

    AND o.transfer_status_id IN (
      4,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,38,39
    )
    AND o.business_id <> 10
),
agg AS (
  SELECT
    week,
    week_start_date,
    distance_type_name,
    sort_order,

    /* 0-200 segmentation (disjoint) */
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >= 0   AND weight <= 1)   AS c_0_1,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  1   AND weight <= 10)  AS c_1_10,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  10  AND weight <= 50)  AS c_10_50,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  50  AND weight <= 100) AS c_50_100,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  100 AND weight <= 200) AS c_100_200,

    /* main slabs */
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >= 0    AND weight <= 200)  AS c_0_200,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  200  AND weight <= 500)  AS c_201_500,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  500  AND weight <= 1000) AS c_501_1000,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  1000 AND weight <= 1500) AS c_1001_1500,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  1500 AND weight <= 2000) AS c_1501_2000,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  2000 AND weight <= 2500) AS c_2001_2500,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  2500 AND weight <= 3000) AS c_2501_3000,
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >  3000)                   AS c_3000_plus,

    /* Distance wise Total (main universe; segmented cols do NOT affect) */
    COUNT(DISTINCT consignment_id) FILTER (WHERE weight IS NOT NULL AND weight >= 0) AS distance_total
  FROM orders_base
  GROUP BY 1,2,3,4
),
grid AS (
  /* ensure each week has all 5 distance rows (even if zero) */
  SELECT
    w.week,
    w.week_start_date,
    w."Start & End Date",
    dt.distance_type_name,
    dt.sort_order
  FROM weeks w
  CROSS JOIN distance_types dt
),
distance_rows AS (
  SELECT
    g.week AS "Week",
    g."Start & End Date",
    g.distance_type_name,

    COALESCE(a.c_0_1, 0)      AS "0-1",
    COALESCE(a.c_1_10, 0)     AS "1-10",
    COALESCE(a.c_10_50, 0)    AS "10-50",
    COALESCE(a.c_50_100, 0)   AS "50-100",
    COALESCE(a.c_100_200, 0)  AS "100-200",

    COALESCE(a.c_0_200, 0)    AS "0-200",
    COALESCE(a.c_201_500, 0)  AS "201-500",
    COALESCE(a.c_501_1000, 0) AS "501-1000",
    COALESCE(a.c_1001_1500, 0) AS "1001-1500",
    COALESCE(a.c_1501_2000, 0) AS "1501-2000",
    COALESCE(a.c_2001_2500, 0) AS "2001-2500",
    COALESCE(a.c_2501_3000, 0) AS "2501-3000",
    COALESCE(a.c_3000_plus, 0) AS "3000+",

    COALESCE(a.distance_total, 0) AS "Distance wise Total",

    /* FRACTION (0-1), NOT *100 */
    ROUND(
      COALESCE(a.distance_total, 0)::numeric
      / NULLIF(SUM(COALESCE(a.distance_total, 0)) OVER (PARTITION BY g.week), 0),
      4
    ) AS "Distance Contribution %",

    1 AS row_order,
    g.sort_order AS sort_key
  FROM grid g
  LEFT JOIN agg a
    ON a.week = g.week
   AND a.week_start_date = g.week_start_date
   AND a.distance_type_name = g.distance_type_name
),
week_totals AS (
  /* totals across distance types (per week) */
  SELECT
    w.week AS "Week",
    w."Start & End Date",

    /* segmented totals */
    SUM(COALESCE(a.c_0_1, 0))     AS t_0_1,
    SUM(COALESCE(a.c_1_10, 0))    AS t_1_10,
    SUM(COALESCE(a.c_10_50, 0))   AS t_10_50,
    SUM(COALESCE(a.c_50_100, 0))  AS t_50_100,
    SUM(COALESCE(a.c_100_200, 0)) AS t_100_200,

    /* main slabs totals */
    SUM(COALESCE(a.c_0_200, 0))    AS t_0_200,
    SUM(COALESCE(a.c_201_500, 0))  AS t_201_500,
    SUM(COALESCE(a.c_501_1000, 0)) AS t_501_1000,
    SUM(COALESCE(a.c_1001_1500, 0)) AS t_1001_1500,
    SUM(COALESCE(a.c_1501_2000, 0)) AS t_1501_2000,
    SUM(COALESCE(a.c_2001_2500, 0)) AS t_2001_2500,
    SUM(COALESCE(a.c_2501_3000, 0)) AS t_2501_3000,
    SUM(COALESCE(a.c_3000_plus, 0)) AS t_3000_plus,

    SUM(COALESCE(a.distance_total, 0)) AS t_distance_total
  FROM weeks w
  LEFT JOIN agg a
    ON a.week = w.week
   AND a.week_start_date = w.week_start_date
  GROUP BY 1,2
),
total_row AS (
  SELECT
    wt."Week",
    wt."Start & End Date",
    'Weight Slab wise Total' AS distance_type_name,

    /* segmented totals = true sums */
    wt.t_0_1     AS "0-1",
    wt.t_1_10    AS "1-10",
    wt.t_10_50   AS "10-50",
    wt.t_50_100  AS "50-100",
    wt.t_100_200 AS "100-200",

    wt.t_0_200     AS "0-200",
    wt.t_201_500   AS "201-500",
    wt.t_501_1000  AS "501-1000",
    wt.t_1001_1500 AS "1001-1500",
    wt.t_1501_2000 AS "1501-2000",
    wt.t_2001_2500 AS "2001-2500",
    wt.t_2501_3000 AS "2501-3000",
    wt.t_3000_plus AS "3000+",

    wt.t_distance_total AS "Distance wise Total",
    1.0000::numeric     AS "Distance Contribution %",

    2 AS row_order,
    6 AS sort_key
  FROM week_totals wt
),
contrib_row AS (
  SELECT
    wt."Week",
    wt."Start & End Date",
    'Contribution %' AS distance_type_name,

    /* segmented contribution = segment_total / total_0_200 (as you asked) */
    ROUND(wt.t_0_1::numeric     / NULLIF(wt.t_0_200, 0), 4) AS "0-1",
    ROUND(wt.t_1_10::numeric    / NULLIF(wt.t_0_200, 0), 4) AS "1-10",
    ROUND(wt.t_10_50::numeric   / NULLIF(wt.t_0_200, 0), 4) AS "10-50",
    ROUND(wt.t_50_100::numeric  / NULLIF(wt.t_0_200, 0), 4) AS "50-100",
    ROUND(wt.t_100_200::numeric / NULLIF(wt.t_0_200, 0), 4) AS "100-200",

    /* main slab contribution = slab_total / sum(all main slabs) = slab_total / distance_total (fraction) */
    ROUND(wt.t_0_200::numeric     / NULLIF(wt.t_distance_total, 0), 4) AS "0-200",
    ROUND(wt.t_201_500::numeric   / NULLIF(wt.t_distance_total, 0), 4) AS "201-500",
    ROUND(wt.t_501_1000::numeric  / NULLIF(wt.t_distance_total, 0), 4) AS "501-1000",
    ROUND(wt.t_1001_1500::numeric / NULLIF(wt.t_distance_total, 0), 4) AS "1001-1500",
    ROUND(wt.t_1501_2000::numeric / NULLIF(wt.t_distance_total, 0), 4) AS "1501-2000",
    ROUND(wt.t_2001_2500::numeric / NULLIF(wt.t_distance_total, 0), 4) AS "2001-2500",
    ROUND(wt.t_2501_3000::numeric / NULLIF(wt.t_distance_total, 0), 4) AS "2501-3000",
    ROUND(wt.t_3000_plus::numeric / NULLIF(wt.t_distance_total, 0), 4) AS "3000+",

    1.0000::numeric AS "Distance wise Total",
    NULL::numeric   AS "Distance Contribution %",

    3 AS row_order,
    7 AS sort_key
  FROM week_totals wt
)
SELECT
  "Week",
  "Start & End Date",
  distance_type_name,
  "0-1","1-10","10-50","50-100","100-200",
  "0-200","201-500","501-1000","1001-1500","1501-2000","2001-2500","2501-3000","3000+",
  "Distance wise Total",
  "Distance Contribution %"
FROM (
  SELECT * FROM distance_rows
  UNION ALL
  SELECT * FROM total_row
  UNION ALL
  SELECT * FROM contrib_row
) x
ORDER BY
  "Week" DESC,
  row_order,
  sort_key;
