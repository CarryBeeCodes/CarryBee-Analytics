/* ============================================================
   Pickup Hub DoD Performance – Summary (with segment sanity)
   - Hub-wise, zone-wise, division-wise, sorted-date-wise
   - Time window based on sorted_at + 6h
   - Transfer statuses included:
       7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
       35,36,37,38,39,42,43

   Updated Hub / Zone / Division logic:
     - 162 Keraniganj-Ati Bazar → Zone: SUB, Division: Dhaka Sub
     - 163 Narayanganj-Bandar   → Zone: SUB, Division: Dhaka Sub
     - 161 Central IB           → Zone: Central Inbound
     - 153–159 (Bhanga / Barishal / Bhairab / Sirajgonj /
               Comilla / Rangpur / Sylhet Sub Sort)
                                 → Zone: Sub Sort
     - 71 Central Sort          → Zone: Central Warehouse
     - 72 Central Return        → Zone: Central Warehouse

   Metrics (per pickup hub, per day):
     * Total Orders (status set)
     * Orders Left Pickup Hub (10+)
     * Orders with Inbound → OTW CW segment (hrs > 0, from logs)
     * Avg Inbound → OTW CW time (hrs, only >0)
     * 7-day rolling avg per hub (on daily avg)
     * Aging buckets (counts & % of segment orders):
          3 hrs, 6 hrs, 9 hrs, 12 hrs, 24 hrs, 24 hrs++
     * Extended buckets 48+ (counts only)

   Extra rows (per day):
     * Zone totals:
          ISD Total, SUB Total, OSD Total (OSD + 3PL),
          Central Inbound Total, Sub Sort Total, Central Warehouse Total
     * Division totals:
          Barisal Total, CTG Total, Dhaka ISD Total,
          Dhaka OSD Total, Dhaka Sub Total, Khulna Total,
          Mymensingh Total, Rajshahi Total, Rangpur Total,
          Sylhet Total, 3PL Total
     * Global Total (sum of all)
   ============================================================ */

WITH
/*----------------------------------------------------------
  1) Hub → Zone + Division map
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    /* Zone type (high-level / special):
       ISD, SUB, 3PL, OSD, Central Inbound, Sub Sort, Central Warehouse */
    CASE
      WHEN h.id = 161 THEN 'Central Inbound'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort'
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type,

    /* Division name (as provided / updated) */
    CASE
      WHEN h.id = 10 THEN '3PL'

      WHEN h.id IN (18,19,20,21,22,50,99,109,115,127)
        THEN 'Barisal'

      WHEN h.id IN (
        23,24,25,26,27,28,29,30,31,
        55,63,69,86,87,88,89,95,96,97,98,
        105,120,126,135,136,137,142,143,
        148,149,150,151,152
      )
        THEN 'CTG'

      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,92,145)
        THEN 'Dhaka ISD'

      WHEN h.id IN (17,32,56,62,70,75,76,79,83,84,85,94,103,106,112,118,119,129,138)
        THEN 'Dhaka OSD'

      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163)
        THEN 'Dhaka Sub'

      WHEN h.id IN (48,58,59,60,61,64,65,66,77,82,100,107,121,122,123,128)
        THEN 'Khulna'

      WHEN h.id IN (33,34,35,67,93,117,133,134)
        THEN 'Mymensingh'

      WHEN h.id IN (36,37,38,39,40,49,51,80,101,102,125,139,140,144)
        THEN 'Rajshahi'

      WHEN h.id IN (41,42,43,52,53,54,57,68,104,124,141)
        THEN 'Rangpur'

      WHEN h.id IN (44,45,46,47,90,108,113,114,116,130,131,132,147)
        THEN 'Sylhet'

      ELSE 'Unknown'
    END AS division_name
  FROM public.hubs h
),

/*----------------------------------------------------------
  2) Base orders: pickup hub, pickup zone, pickup division, sorted date
----------------------------------------------------------*/
base AS (
  SELECT
    o.id                                     AS order_id,
    o.transfer_status_id,
    o.sorted_at,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date,  -- "Hub Order Date"
    ph.id                                    AS pickup_hub_id,
    ph.name                                  AS pickup_hub_name,
    phz.zone_type                            AS pickup_zone_type,
    phz.division_name                        AS pickup_division_name
  FROM public.orders o
  LEFT JOIN public.hubs  ph  ON ph.id = o.pickup_hub_id
  LEFT JOIN hub_zone_map phz ON phz.hub_id = ph.id
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-02 00:00:00'  -- <== adjust end date as needed

    /* Transfer status filter – full pickup/flow set */
    AND o.transfer_status_id IN (
      7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
    AND o.pickup_hub_id IS NOT NULL
),

/*----------------------------------------------------------
  3) Per-order log-derived times for Inbound & OTW to CW
----------------------------------------------------------*/
flow AS (
  SELECT
    b.*,

    /* Inbound at: earliest 7 or 9 */
    la.inbound_at_raw,

    /* On the way to Central Warehouse: first 10, else 35 */
    otw_cw.on_way_cw_raw,

    /* Numeric aging in hours: Inbound → On the way to CW */
    CASE
      WHEN la.inbound_at_raw IS NOT NULL
       AND otw_cw.on_way_cw_raw IS NOT NULL
      THEN EXTRACT(EPOCH FROM (otw_cw.on_way_cw_raw - la.inbound_at_raw)) / 3600.0
    END AS inbound_to_cw_hours
  FROM base b

  /* Inbound: earliest status 7 or 9 */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status IN (7,9) THEN ol.created_at END) AS inbound_at_raw
    FROM public.order_logs ol
    WHERE ol.order_id = b.order_id
  ) la ON TRUE

  /* On the way to Central Warehouse: first 10, else 35 */
  LEFT JOIN LATERAL (
    SELECT
      ol.created_at AS on_way_cw_raw
    FROM public.order_logs ol
    WHERE ol.order_id = b.order_id
      AND (ol.current_status = 10 OR ol.current_status = 35)
    ORDER BY
      CASE WHEN ol.current_status = 10 THEN 1 ELSE 2 END,
      ol.created_at,
      ol.id
    LIMIT 1
  ) otw_cw ON TRUE
),

/*----------------------------------------------------------
  4) Aggregation per pickup hub / zone / division / order_date (raw)
     - keep SUM of hours so we can recompute averages at hub & zone/div/global level
----------------------------------------------------------*/
aggregated_raw AS (
  SELECT
    f.order_date,
    f.pickup_hub_id,
    f.pickup_hub_name,
    f.pickup_zone_type,
    f.pickup_division_name,

    /* 1. Total orders in this status set for that hub & day */
    COUNT(*) AS total_orders,

    /* 2. Orders that have left the pickup hub (status moved to 10+) */
    COUNT(*) FILTER (
      WHERE f.transfer_status_id IN (
        10,11,12,13,14,15,16,17,18,19,20,21,22,
        35,36,37,38,39,42,43
      )
    ) AS orders_left_pickup_hub,

    /* 3. Orders that actually have a positive Inbound→CW segment (from logs) */
    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 0
    ) AS orders_with_inbound_segment,

    /* Sum of Inbound→CW hours for valid segment orders */
    SUM(
      CASE
        WHEN f.inbound_to_cw_hours > 0 THEN f.inbound_to_cw_hours
      END
    ) AS sum_inbound_processing_hours,

    /* 4. Aging buckets – counts, only on inbound_to_cw_hours >0 */
    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 0
        AND f.inbound_to_cw_hours <= 3
    ) AS cnt_0_3,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 3
        AND f.inbound_to_cw_hours <= 6
    ) AS cnt_3_6,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 6
        AND f.inbound_to_cw_hours <= 9
    ) AS cnt_6_9,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 9
        AND f.inbound_to_cw_hours <= 12
    ) AS cnt_9_12,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 12
        AND f.inbound_to_cw_hours <= 24
    ) AS cnt_12_24,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 24
        AND f.inbound_to_cw_hours <= 36
    ) AS cnt_24_36,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 36
        AND f.inbound_to_cw_hours <= 48
    ) AS cnt_36_48,

    /* Extended aging buckets beyond 48 hrs (24-hr bands up to 480) */
    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 48
        AND f.inbound_to_cw_hours <= 72
    ) AS cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 72
        AND f.inbound_to_cw_hours <= 96
    ) AS cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 96
        AND f.inbound_to_cw_hours <= 120
    ) AS cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 120
        AND f.inbound_to_cw_hours <= 144
    ) AS cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 144
        AND f.inbound_to_cw_hours <= 168
    ) AS cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 168
        AND f.inbound_to_cw_hours <= 192
    ) AS cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 192
        AND f.inbound_to_cw_hours <= 216
    ) AS cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 216
        AND f.inbound_to_cw_hours <= 240
    ) AS cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 240
        AND f.inbound_to_cw_hours <= 264
    ) AS cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 264
        AND f.inbound_to_cw_hours <= 288
    ) AS cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 288
        AND f.inbound_to_cw_hours <= 312
    ) AS cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 312
        AND f.inbound_to_cw_hours <= 336
    ) AS cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 336
        AND f.inbound_to_cw_hours <= 360
    ) AS cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 360
        AND f.inbound_to_cw_hours <= 384
    ) AS cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 384
        AND f.inbound_to_cw_hours <= 408
    ) AS cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 408
        AND f.inbound_to_cw_hours <= 432
    ) AS cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 432
        AND f.inbound_to_cw_hours <= 456
    ) AS cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 456
        AND f.inbound_to_cw_hours <= 480
    ) AS cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.inbound_to_cw_hours > 480
    ) AS cnt_480_plus
  FROM flow f
  GROUP BY
    f.order_date,
    f.pickup_hub_id,
    f.pickup_hub_name,
    f.pickup_zone_type,
    f.pickup_division_name
),

/*----------------------------------------------------------
  5) Hub-level metrics (compute avg & rolling avg)
----------------------------------------------------------*/
hub_metrics_base AS (
  SELECT
    ar.order_date,
    ar.pickup_hub_id,
    ar.pickup_hub_name,
    ar.pickup_zone_type,
    ar.pickup_division_name,
    ar.total_orders,
    ar.orders_left_pickup_hub,
    ar.orders_with_inbound_segment,
    CASE
      WHEN ar.orders_with_inbound_segment > 0
      THEN ar.sum_inbound_processing_hours / ar.orders_with_inbound_segment
    END AS avg_inbound_processing_hours,
    ar.cnt_0_3,
    ar.cnt_3_6,
    ar.cnt_6_9,
    ar.cnt_9_12,
    ar.cnt_12_24,
    ar.cnt_24_36,
    ar.cnt_36_48,
    ar.cnt_48_72,
    ar.cnt_72_96,
    ar.cnt_96_120,
    ar.cnt_120_144,
    ar.cnt_144_168,
    ar.cnt_168_192,
    ar.cnt_192_216,
    ar.cnt_216_240,
    ar.cnt_240_264,
    ar.cnt_264_288,
    ar.cnt_288_312,
    ar.cnt_312_336,
    ar.cnt_336_360,
    ar.cnt_360_384,
    ar.cnt_384_408,
    ar.cnt_408_432,
    ar.cnt_432_456,
    ar.cnt_456_480,
    ar.cnt_480_plus
  FROM aggregated_raw ar
),

hub_metrics AS (
  SELECT
    hmb.*,
    AVG(hmb.avg_inbound_processing_hours) OVER (
      PARTITION BY hmb.pickup_hub_id
      ORDER BY hmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_processing_hours
  FROM hub_metrics_base hmb
),

/*----------------------------------------------------------
  6) Zone-level totals (OSD + 3PL combined into OSD)
----------------------------------------------------------*/
zone_agg_raw AS (
  SELECT
    ar.order_date,
    CASE
      WHEN ar.pickup_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE ar.pickup_zone_type
    END AS pickup_zone_type,
    SUM(ar.total_orders)                AS total_orders,
    SUM(ar.orders_left_pickup_hub)      AS orders_left_pickup_hub,
    SUM(ar.orders_with_inbound_segment) AS orders_with_inbound_segment,
    SUM(ar.sum_inbound_processing_hours) AS sum_inbound_processing_hours,
    SUM(ar.cnt_0_3)     AS cnt_0_3,
    SUM(ar.cnt_3_6)     AS cnt_3_6,
    SUM(ar.cnt_6_9)     AS cnt_6_9,
    SUM(ar.cnt_9_12)    AS cnt_9_12,
    SUM(ar.cnt_12_24)   AS cnt_12_24,
    SUM(ar.cnt_24_36)   AS cnt_24_36,
    SUM(ar.cnt_36_48)   AS cnt_36_48,
    SUM(ar.cnt_48_72)   AS cnt_48_72,
    SUM(ar.cnt_72_96)   AS cnt_72_96,
    SUM(ar.cnt_96_120)  AS cnt_96_120,
    SUM(ar.cnt_120_144) AS cnt_120_144,
    SUM(ar.cnt_144_168) AS cnt_144_168,
    SUM(ar.cnt_168_192) AS cnt_168_192,
    SUM(ar.cnt_192_216) AS cnt_192_216,
    SUM(ar.cnt_216_240) AS cnt_216_240,
    SUM(ar.cnt_240_264) AS cnt_240_264,
    SUM(ar.cnt_264_288) AS cnt_264_288,
    SUM(ar.cnt_288_312) AS cnt_288_312,
    SUM(ar.cnt_312_336) AS cnt_312_336,
    SUM(ar.cnt_336_360) AS cnt_336_360,
    SUM(ar.cnt_360_384) AS cnt_360_384,
    SUM(ar.cnt_384_408) AS cnt_384_408,
    SUM(ar.cnt_408_432) AS cnt_408_432,
    SUM(ar.cnt_432_456) AS cnt_432_456,
    SUM(ar.cnt_456_480) AS cnt_456_480,
    SUM(ar.cnt_480_plus) AS cnt_480_plus
  FROM aggregated_raw ar
  GROUP BY
    ar.order_date,
    CASE
      WHEN ar.pickup_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE ar.pickup_zone_type
    END
),

zone_metrics_base AS (
  SELECT
    z.order_date,
    NULL::integer AS pickup_hub_id,
    CASE
      WHEN z.pickup_zone_type = 'ISD' THEN 'ISD Total'
      WHEN z.pickup_zone_type = 'SUB' THEN 'SUB Total'
      WHEN z.pickup_zone_type = 'OSD' THEN 'OSD Total'   -- OSD + 3PL
      ELSE z.pickup_zone_type || ' Total'
    END AS pickup_hub_name,
    z.pickup_zone_type,
    NULL::text AS pickup_division_name,
    z.total_orders,
    z.orders_left_pickup_hub,
    z.orders_with_inbound_segment,
    CASE
      WHEN z.orders_with_inbound_segment > 0
      THEN z.sum_inbound_processing_hours / z.orders_with_inbound_segment
    END AS avg_inbound_processing_hours,
    z.cnt_0_3,
    z.cnt_3_6,
    z.cnt_6_9,
    z.cnt_9_12,
    z.cnt_12_24,
    z.cnt_24_36,
    z.cnt_36_48,
    z.cnt_48_72,
    z.cnt_72_96,
    z.cnt_96_120,
    z.cnt_120_144,
    z.cnt_144_168,
    z.cnt_168_192,
    z.cnt_192_216,
    z.cnt_216_240,
    z.cnt_240_264,
    z.cnt_264_288,
    z.cnt_288_312,
    z.cnt_312_336,
    z.cnt_336_360,
    z.cnt_360_384,
    z.cnt_384_408,
    z.cnt_408_432,
    z.cnt_432_456,
    z.cnt_456_480,
    z.cnt_480_plus
  FROM zone_agg_raw z
),

zone_metrics AS (
  SELECT
    zmb.*,
    AVG(zmb.avg_inbound_processing_hours) OVER (
      PARTITION BY zmb.pickup_zone_type
      ORDER BY zmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_processing_hours
  FROM zone_metrics_base zmb
),

/*----------------------------------------------------------
  7) Division-level totals
----------------------------------------------------------*/
division_agg_raw AS (
  SELECT
    ar.order_date,
    ar.pickup_zone_type,
    ar.pickup_division_name,
    SUM(ar.total_orders)                AS total_orders,
    SUM(ar.orders_left_pickup_hub)      AS orders_left_pickup_hub,
    SUM(ar.orders_with_inbound_segment) AS orders_with_inbound_segment,
    SUM(ar.sum_inbound_processing_hours) AS sum_inbound_processing_hours,
    SUM(ar.cnt_0_3)     AS cnt_0_3,
    SUM(ar.cnt_3_6)     AS cnt_3_6,
    SUM(ar.cnt_6_9)     AS cnt_6_9,
    SUM(ar.cnt_9_12)    AS cnt_9_12,
    SUM(ar.cnt_12_24)   AS cnt_12_24,
    SUM(ar.cnt_24_36)   AS cnt_24_36,
    SUM(ar.cnt_36_48)   AS cnt_36_48,
    SUM(ar.cnt_48_72)   AS cnt_48_72,
    SUM(ar.cnt_72_96)   AS cnt_72_96,
    SUM(ar.cnt_96_120)  AS cnt_96_120,
    SUM(ar.cnt_120_144) AS cnt_120_144,
    SUM(ar.cnt_144_168) AS cnt_144_168,
    SUM(ar.cnt_168_192) AS cnt_168_192,
    SUM(ar.cnt_192_216) AS cnt_192_216,
    SUM(ar.cnt_216_240) AS cnt_216_240,
    SUM(ar.cnt_240_264) AS cnt_240_264,
    SUM(ar.cnt_264_288) AS cnt_264_288,
    SUM(ar.cnt_288_312) AS cnt_288_312,
    SUM(ar.cnt_312_336) AS cnt_312_336,
    SUM(ar.cnt_336_360) AS cnt_336_360,
    SUM(ar.cnt_360_384) AS cnt_360_384,
    SUM(ar.cnt_384_408) AS cnt_384_408,
    SUM(ar.cnt_408_432) AS cnt_408_432,
    SUM(ar.cnt_432_456) AS cnt_432_456,
    SUM(ar.cnt_456_480) AS cnt_456_480,
    SUM(ar.cnt_480_plus) AS cnt_480_plus
  FROM aggregated_raw ar
  WHERE ar.pickup_division_name IS NOT NULL
  GROUP BY
    ar.order_date,
    ar.pickup_zone_type,
    ar.pickup_division_name
),

division_metrics_base AS (
  SELECT
    d.order_date,
    NULL::integer AS pickup_hub_id,
    d.pickup_division_name || ' Total' AS pickup_hub_name,
    d.pickup_zone_type,
    d.pickup_division_name,
    d.total_orders,
    d.orders_left_pickup_hub,
    d.orders_with_inbound_segment,
    CASE
      WHEN d.orders_with_inbound_segment > 0
      THEN d.sum_inbound_processing_hours / d.orders_with_inbound_segment
    END AS avg_inbound_processing_hours,
    d.cnt_0_3,
    d.cnt_3_6,
    d.cnt_6_9,
    d.cnt_9_12,
    d.cnt_12_24,
    d.cnt_24_36,
    d.cnt_36_48,
    d.cnt_48_72,
    d.cnt_72_96,
    d.cnt_96_120,
    d.cnt_120_144,
    d.cnt_144_168,
    d.cnt_168_192,
    d.cnt_192_216,
    d.cnt_216_240,
    d.cnt_240_264,
    d.cnt_264_288,
    d.cnt_288_312,
    d.cnt_312_336,
    d.cnt_336_360,
    d.cnt_360_384,
    d.cnt_384_408,
    d.cnt_408_432,
    d.cnt_432_456,
    d.cnt_456_480,
    d.cnt_480_plus
  FROM division_agg_raw d
),

division_metrics AS (
  SELECT
    dmb.*,
    AVG(dmb.avg_inbound_processing_hours) OVER (
      PARTITION BY dmb.pickup_division_name
      ORDER BY dmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_processing_hours
  FROM division_metrics_base dmb
),

/*----------------------------------------------------------
  8) Global totals (all zones & divisions combined)
----------------------------------------------------------*/
global_agg_raw AS (
  SELECT
    ar.order_date,
    SUM(ar.total_orders)                AS total_orders,
    SUM(ar.orders_left_pickup_hub)      AS orders_left_pickup_hub,
    SUM(ar.orders_with_inbound_segment) AS orders_with_inbound_segment,
    SUM(ar.sum_inbound_processing_hours) AS sum_inbound_processing_hours,
    SUM(ar.cnt_0_3)     AS cnt_0_3,
    SUM(ar.cnt_3_6)     AS cnt_3_6,
    SUM(ar.cnt_6_9)     AS cnt_6_9,
    SUM(ar.cnt_9_12)    AS cnt_9_12,
    SUM(ar.cnt_12_24)   AS cnt_12_24,
    SUM(ar.cnt_24_36)   AS cnt_24_36,
    SUM(ar.cnt_36_48)   AS cnt_36_48,
    SUM(ar.cnt_48_72)   AS cnt_48_72,
    SUM(ar.cnt_72_96)   AS cnt_72_96,
    SUM(ar.cnt_96_120)  AS cnt_96_120,
    SUM(ar.cnt_120_144) AS cnt_120_144,
    SUM(ar.cnt_144_168) AS cnt_144_168,
    SUM(ar.cnt_168_192) AS cnt_168_192,
    SUM(ar.cnt_192_216) AS cnt_192_216,
    SUM(ar.cnt_216_240) AS cnt_216_240,
    SUM(ar.cnt_240_264) AS cnt_240_264,
    SUM(ar.cnt_264_288) AS cnt_264_288,
    SUM(ar.cnt_288_312) AS cnt_288_312,
    SUM(ar.cnt_312_336) AS cnt_312_336,
    SUM(ar.cnt_336_360) AS cnt_336_360,
    SUM(ar.cnt_360_384) AS cnt_360_384,
    SUM(ar.cnt_384_408) AS cnt_384_408,
    SUM(ar.cnt_408_432) AS cnt_408_432,
    SUM(ar.cnt_432_456) AS cnt_432_456,
    SUM(ar.cnt_456_480) AS cnt_456_480,
    SUM(ar.cnt_480_plus) AS cnt_480_plus
  FROM aggregated_raw ar
  GROUP BY ar.order_date
),

global_metrics_base AS (
  SELECT
    ga.order_date,
    NULL::integer AS pickup_hub_id,
    'Global Total' AS pickup_hub_name,
    'Global' AS pickup_zone_type,
    NULL::text AS pickup_division_name,
    ga.total_orders,
    ga.orders_left_pickup_hub,
    ga.orders_with_inbound_segment,
    CASE
      WHEN ga.orders_with_inbound_segment > 0
      THEN ga.sum_inbound_processing_hours / ga.orders_with_inbound_segment
    END AS avg_inbound_processing_hours,
    ga.cnt_0_3,
    ga.cnt_3_6,
    ga.cnt_6_9,
    ga.cnt_9_12,
    ga.cnt_12_24,
    ga.cnt_24_36,
    ga.cnt_36_48,
    ga.cnt_48_72,
    ga.cnt_72_96,
    ga.cnt_96_120,
    ga.cnt_120_144,
    ga.cnt_144_168,
    ga.cnt_168_192,
    ga.cnt_192_216,
    ga.cnt_216_240,
    ga.cnt_240_264,
    ga.cnt_264_288,
    ga.cnt_288_312,
    ga.cnt_312_336,
    ga.cnt_336_360,
    ga.cnt_360_384,
    ga.cnt_384_408,
    ga.cnt_408_432,
    ga.cnt_432_456,
    ga.cnt_456_480,
    ga.cnt_480_plus
  FROM global_agg_raw ga
),

global_metrics AS (
  SELECT
    gmb.*,
    AVG(gmb.avg_inbound_processing_hours) OVER (
      ORDER BY gmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_processing_hours
  FROM global_metrics_base gmb
),

/*----------------------------------------------------------
  9) Combine hub rows + zone totals + division totals + global totals
----------------------------------------------------------*/
combined AS (
  SELECT
    hm.order_date,
    hm.pickup_hub_id,
    hm.pickup_hub_name,
    hm.pickup_zone_type,
    hm.pickup_division_name,
    hm.total_orders,
    hm.orders_left_pickup_hub,
    hm.orders_with_inbound_segment,
    hm.avg_inbound_processing_hours,
    hm.last_7_days_avg_processing_hours,
    hm.cnt_0_3,
    hm.cnt_3_6,
    hm.cnt_6_9,
    hm.cnt_9_12,
    hm.cnt_12_24,
    hm.cnt_24_36,
    hm.cnt_36_48,
    hm.cnt_48_72,
    hm.cnt_72_96,
    hm.cnt_96_120,
    hm.cnt_120_144,
    hm.cnt_144_168,
    hm.cnt_168_192,
    hm.cnt_192_216,
    hm.cnt_216_240,
    hm.cnt_240_264,
    hm.cnt_264_288,
    hm.cnt_288_312,
    hm.cnt_312_336,
    hm.cnt_336_360,
    hm.cnt_360_384,
    hm.cnt_384_408,
    hm.cnt_408_432,
    hm.cnt_432_456,
    hm.cnt_456_480,
    hm.cnt_480_plus
  FROM hub_metrics hm

  UNION ALL

  SELECT
    zm.order_date,
    zm.pickup_hub_id,
    zm.pickup_hub_name,
    zm.pickup_zone_type,
    zm.pickup_division_name,
    zm.total_orders,
    zm.orders_left_pickup_hub,
    zm.orders_with_inbound_segment,
    zm.avg_inbound_processing_hours,
    zm.last_7_days_avg_processing_hours,
    zm.cnt_0_3,
    zm.cnt_3_6,
    zm.cnt_6_9,
    zm.cnt_9_12,
    zm.cnt_12_24,
    zm.cnt_24_36,
    zm.cnt_36_48,
    zm.cnt_48_72,
    zm.cnt_72_96,
    zm.cnt_96_120,
    zm.cnt_120_144,
    zm.cnt_144_168,
    zm.cnt_168_192,
    zm.cnt_192_216,
    zm.cnt_216_240,
    zm.cnt_240_264,
    zm.cnt_264_288,
    zm.cnt_288_312,
    zm.cnt_312_336,
    zm.cnt_336_360,
    zm.cnt_360_384,
    zm.cnt_384_408,
    zm.cnt_408_432,
    zm.cnt_432_456,
    zm.cnt_456_480,
    zm.cnt_480_plus
  FROM zone_metrics zm

  UNION ALL

  SELECT
    dm.order_date,
    dm.pickup_hub_id,
    dm.pickup_hub_name,
    dm.pickup_zone_type,
    dm.pickup_division_name,
    dm.total_orders,
    dm.orders_left_pickup_hub,
    dm.orders_with_inbound_segment,
    dm.avg_inbound_processing_hours,
    dm.last_7_days_avg_processing_hours,
    dm.cnt_0_3,
    dm.cnt_3_6,
    dm.cnt_6_9,
    dm.cnt_9_12,
    dm.cnt_12_24,
    dm.cnt_24_36,
    dm.cnt_36_48,
    dm.cnt_48_72,
    dm.cnt_72_96,
    dm.cnt_96_120,
    dm.cnt_120_144,
    dm.cnt_144_168,
    dm.cnt_168_192,
    dm.cnt_192_216,
    dm.cnt_216_240,
    dm.cnt_240_264,
    dm.cnt_264_288,
    dm.cnt_288_312,
    dm.cnt_312_336,
    dm.cnt_336_360,
    dm.cnt_360_384,
    dm.cnt_384_408,
    dm.cnt_408_432,
    dm.cnt_432_456,
    dm.cnt_456_480,
    dm.cnt_480_plus
  FROM division_metrics dm

  UNION ALL

  SELECT
    gm.order_date,
    gm.pickup_hub_id,
    gm.pickup_hub_name,
    gm.pickup_zone_type,
    gm.pickup_division_name,
    gm.total_orders,
    gm.orders_left_pickup_hub,
    gm.orders_with_inbound_segment,
    gm.avg_inbound_processing_hours,
    gm.last_7_days_avg_processing_hours,
    gm.cnt_0_3,
    gm.cnt_3_6,
    gm.cnt_6_9,
    gm.cnt_9_12,
    gm.cnt_12_24,
    gm.cnt_24_36,
    gm.cnt_36_48,
    gm.cnt_48_72,
    gm.cnt_72_96,
    gm.cnt_96_120,
    gm.cnt_120_144,
    gm.cnt_144_168,
    gm.cnt_168_192,
    gm.cnt_192_216,
    gm.cnt_216_240,
    gm.cnt_240_264,
    gm.cnt_264_288,
    gm.cnt_288_312,
    gm.cnt_312_336,
    gm.cnt_336_360,
    gm.cnt_360_384,
    gm.cnt_384_408,
    gm.cnt_408_432,
    gm.cnt_432_456,
    gm.cnt_456_480,
    gm.cnt_480_plus
  FROM global_metrics gm
)

/*----------------------------------------------------------
  10) Final select – add % columns (no *100, Excel will format)
----------------------------------------------------------*/
SELECT
  c.order_date       AS "Order Date",
  --c.pickup_hub_id    AS "Pickup Hub ID",
  c.pickup_hub_name  AS "Pickup Hub Name",
  c.pickup_zone_type AS "Pickup Zone",
  c.pickup_division_name AS "Pickup Division",

  c.total_orders                AS "Total Orders",
  c.orders_left_pickup_hub      AS "Orders Left Pickup Hub",
  c.orders_with_inbound_segment AS "Orders with Inbound to OTW CW Segment",

  ROUND(c.avg_inbound_processing_hours, 2)
    AS "Avg Inbound Processing Time (hrs)",

  ROUND(c.last_7_days_avg_processing_hours, 2)
    AS "Last 7 days avg processing time",

  /* === Main aging buckets (counts) – only for orders WITH segment === */
  c.cnt_0_3 AS "3 hrs",          -- 0–3 hrs
  c.cnt_3_6 AS "6 hrs",          -- >3–6 hrs
  c.cnt_6_9 AS "9 hrs",          -- >6–9 hrs
  c.cnt_9_12 AS "12 hrs",        -- >9–12 hrs
  c.cnt_12_24 AS "24 hrs",       -- >12–24 hrs
  (
    c.cnt_24_36
    + c.cnt_36_48
    + c.cnt_48_72
    + c.cnt_72_96
    + c.cnt_96_120
    + c.cnt_120_144
    + c.cnt_144_168
    + c.cnt_168_192
    + c.cnt_192_216
    + c.cnt_216_240
    + c.cnt_240_264
    + c.cnt_264_288
    + c.cnt_288_312
    + c.cnt_312_336
    + c.cnt_336_360
    + c.cnt_360_384
    + c.cnt_384_408
    + c.cnt_408_432
    + c.cnt_432_456
    + c.cnt_456_480
    + c.cnt_480_plus
  ) AS "24 hrs++",               -- >24 hrs (all higher brackets combined)

  /* === Main aging buckets – FRACTION of orders_with_inbound_segment (no *100) === */
  ROUND(
    c.cnt_0_3 / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 3 hrs",

  ROUND(
    c.cnt_3_6 / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 6 hrs",

  ROUND(
    c.cnt_6_9 / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 9 hrs",

  ROUND(
    c.cnt_9_12 / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 12 hrs",

  ROUND(
    c.cnt_12_24 / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 24 hrs",

  ROUND(
    (
      c.cnt_24_36
      + c.cnt_36_48
      + c.cnt_48_72
      + c.cnt_72_96
      + c.cnt_96_120
      + c.cnt_120_144
      + c.cnt_144_168
      + c.cnt_168_192
      + c.cnt_192_216
      + c.cnt_216_240
      + c.cnt_240_264
      + c.cnt_264_288
      + c.cnt_288_312
      + c.cnt_312_336
      + c.cnt_336_360
      + c.cnt_360_384
      + c.cnt_384_408
      + c.cnt_408_432
      + c.cnt_432_456
      + c.cnt_456_480
      + c.cnt_480_plus
    ) / NULLIF(c.orders_with_inbound_segment, 0),
    2
  ) AS "% 24 hrs++",

  /* === Extended aging buckets (counts only, 24-hr bands from 48+) === */
  c.cnt_48_72    AS "48 hrs",     -- >48–72 hrs
  c.cnt_72_96    AS "72 hrs",     -- >72–96 hrs
  c.cnt_96_120   AS "96 hrs",     -- >96–120 hrs
  c.cnt_120_144  AS "120 hrs",    -- >120–144 hrs
  c.cnt_144_168  AS "144 hrs",    -- >144–168 hrs
  c.cnt_168_192  AS "168 hrs",    -- >168–192 hrs
  c.cnt_192_216  AS "192 hrs",    -- >192–216 hrs
  c.cnt_216_240  AS "216 hrs",    -- >216–240 hrs
  c.cnt_240_264  AS "240 hrs",    -- >240–264 hrs
  c.cnt_264_288  AS "264 hrs",    -- >264–288 hrs
  c.cnt_288_312  AS "288 hrs",    -- >288–312 hrs
  c.cnt_312_336  AS "312 hrs",    -- >312–336 hrs
  c.cnt_336_360  AS "336 hrs",    -- >336–360 hrs
  c.cnt_360_384  AS "360 hrs",    -- >360–384 hrs
  c.cnt_384_408  AS "384 hrs",    -- >384–408 hrs
  c.cnt_408_432  AS "408 hrs",    -- >408–432 hrs
  c.cnt_432_456  AS "432 hrs",    -- >432–456 hrs
  c.cnt_456_480  AS "456 hrs",    -- >456–480 hrs
  c.cnt_480_plus AS "480 hrs++"   -- >480 hrs

FROM combined c
ORDER BY
  c.order_date DESC,
  c.pickup_zone_type,
  c.pickup_division_name,
  c.pickup_hub_name;
