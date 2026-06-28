/* ============================================================
   Transport Performance – OTW to LMH (Last Mile Hub DoD)
   - DoD = (sorted_at + 6h)::date  [by delivery hub]
   - Status set (ORDERS.transfer_status_id):
       12,13,14,15,16,17,18,19,20,21,22,
       35,36,37,38,39,42,43

   Metrics (per hub / zone / division / global, per day):
     * Total Processed Orders (status set)
     * Avg OTW to LMH Processing Time (hrs) – only otw_to_lmh_hours > 0
     * Last 7 days avg OTW to LMH Processing Time (hrs)
     * Aging buckets (counts & FRACTIONS of total_processed_orders):
         6 hrs, 12 hrs, 18 hrs, 24 hrs, 36 hrs, 48 hrs, 48 hrs++
     * Extended aging buckets (counts only, 24-hr bands from 72+):
         72 hrs, 96 hrs, ..., 480 hrs, 480 hrs++

   Zone / hub mapping updates applied:
     - 162 Keraniganj-Ati Bazar → Zone: SUB, Division: Dhaka Sub
     - 163 Narayanganj-Bandar   → Zone: SUB, Division: Dhaka Sub
     - 161 Central IB           → Zone: Central Inbound
     - 153–159 (Bhanga / Barishal / Bhairab / Sirajgonj /
               Comilla / Rangpur / Sylhet Sub Sort)
                                 → Zone: Sub Sort
     - 71 Central Sort          → Zone: Central Warehouse
     - 72 Central Return        → Zone: Central Warehouse

   NOTE:
     - All "%" columns are FRACTIONS (0–1). Format as % in Excel/Sheets.
     - Ignore otw_to_lmh_hours <= 0 in averages and buckets.
     - Division totals, Zone totals (ISD/SUB/OSD + new zones), and Global totals included.
   ============================================================ */

WITH
/*----------------------------------------------------------
  1) Hub → Zone + Division map (UPDATED)
----------------------------------------------------------*/
hub_zone_div_map AS (
  SELECT
    h.id AS hub_id,

    /* Zone type (ISD, SUB, 3PL, OSD, Central Inbound, Sub Sort, Central Warehouse) */
    CASE
      WHEN h.id = 161 THEN 'Central Inbound'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort'
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type,

    /* Division name mapping (with 162,163 → Dhaka Sub) */
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
  FROM hubs h
),

/*----------------------------------------------------------
  2) Base orders: delivery hub, zone, division, order date
     DoD = (sorted_at + 6h)::date
----------------------------------------------------------*/
base AS (
  SELECT
    o.id                                      AS order_id,
    o.transfer_status_id,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date,
    dh.id                                     AS delivery_hub_id,
    dh.name                                   AS delivery_hub_name,
    hzd.zone_type                             AS delivery_zone_type,
    hzd.division_name                         AS delivery_division_name
  FROM orders o
  LEFT JOIN hubs             dh  ON dh.id = o.delivery_hub_id
  LEFT JOIN hub_zone_div_map hzd ON hzd.hub_id = dh.id
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-01 00:00:00'
    AND o.transfer_status_id IN (
      12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
    AND o.delivery_hub_id IS NOT NULL
),

/*----------------------------------------------------------
  3) Per-order OTW→LMH timestamps & aging
----------------------------------------------------------*/
flow AS (
  SELECT
    b.*,
    lmh_stats.lmh_logs_raw,
    otw_lmh.on_way_lmh_raw,

    /* OTW to LMH Processing Time (hrs) */
    CASE
      WHEN lmh_stats.lmh_logs_raw IS NOT NULL
       AND otw_lmh.on_way_lmh_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (lmh_stats.lmh_logs_raw - otw_lmh.on_way_lmh_raw)
             ) / 3600.0,
           2)
    END AS otw_to_lmh_hours
  FROM base b

  /* LMH arrival: earliest status 13 in logs */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status = 13 THEN ol.created_at END)
        AS lmh_logs_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
  ) lmh_stats ON TRUE

  /* OTW to LMH: earliest 12, else 35 with hub_id = 71 */
  LEFT JOIN LATERAL (
    SELECT
      ol.created_at AS on_way_lmh_raw
    FROM order_logs ol
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
  4) Aggregation per delivery hub / zone / division / order_date
----------------------------------------------------------*/
aggregated_raw AS (
  SELECT
    f.order_date,
    f.delivery_hub_id,
    f.delivery_hub_name,
    f.delivery_zone_type,
    f.delivery_division_name,

    /* Total processed orders (status set) */
    COUNT(*) AS total_processed_orders,

    /* Valid OTW→LMH segments (hrs >0) – internal only */
    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 0
    ) AS valid_otw_lmh_count,

    /* Sum of hours for valid segments */
    SUM(
      CASE
        WHEN f.otw_to_lmh_hours > 0 THEN f.otw_to_lmh_hours
      END
    ) AS sum_otw_lmh_hours,

    /* Main aging buckets – counts (ignore <=0 or NULL)
       0–6, 6–12, 12–18, 18–24, 24–36, 36–48, >48
    */
    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 0 AND f.otw_to_lmh_hours <= 6
    ) AS lmh_cnt_0_6,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 6 AND f.otw_to_lmh_hours <= 12
    ) AS lmh_cnt_6_12,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 12 AND f.otw_to_lmh_hours <= 18
    ) AS lmh_cnt_12_18,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 18 AND f.otw_to_lmh_hours <= 24
    ) AS lmh_cnt_18_24,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 24 AND f.otw_to_lmh_hours <= 36
    ) AS lmh_cnt_24_36,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 36 AND f.otw_to_lmh_hours <= 48
    ) AS lmh_cnt_36_48,

    /* Underlying >48 buckets up to 480+ */
    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 48 AND f.otw_to_lmh_hours <= 72
    ) AS lmh_cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 72 AND f.otw_to_lmh_hours <= 96
    ) AS lmh_cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 96 AND f.otw_to_lmh_hours <= 120
    ) AS lmh_cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 120 AND f.otw_to_lmh_hours <= 144
    ) AS lmh_cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 144 AND f.otw_to_lmh_hours <= 168
    ) AS lmh_cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 168 AND f.otw_to_lmh_hours <= 192
    ) AS lmh_cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 192 AND f.otw_to_lmh_hours <= 216
    ) AS lmh_cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 216 AND f.otw_to_lmh_hours <= 240
    ) AS lmh_cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 240 AND f.otw_to_lmh_hours <= 264
    ) AS lmh_cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 264 AND f.otw_to_lmh_hours <= 288
    ) AS lmh_cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 288 AND f.otw_to_lmh_hours <= 312
    ) AS lmh_cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 312 AND f.otw_to_lmh_hours <= 336
    ) AS lmh_cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 336 AND f.otw_to_lmh_hours <= 360
    ) AS lmh_cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 360 AND f.otw_to_lmh_hours <= 384
    ) AS lmh_cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 384 AND f.otw_to_lmh_hours <= 408
    ) AS lmh_cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 408 AND f.otw_to_lmh_hours <= 432
    ) AS lmh_cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 432 AND f.otw_to_lmh_hours <= 456
    ) AS lmh_cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 456 AND f.otw_to_lmh_hours <= 480
    ) AS lmh_cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.otw_to_lmh_hours > 480
    ) AS lmh_cnt_480_plus
  FROM flow f
  GROUP BY
    f.order_date,
    f.delivery_hub_id,
    f.delivery_hub_name,
    f.delivery_zone_type,
    f.delivery_division_name
),

/*----------------------------------------------------------
  5) Hub-level metrics (compute averages + rolling averages)
----------------------------------------------------------*/
hub_metrics_base AS (
  SELECT
    ar.order_date,
    ar.delivery_hub_id,
    ar.delivery_hub_name,
    ar.delivery_zone_type,
    ar.delivery_division_name,
    ar.total_processed_orders,
    ar.valid_otw_lmh_count,

    CASE
      WHEN ar.valid_otw_lmh_count > 0
      THEN ar.sum_otw_lmh_hours / ar.valid_otw_lmh_count
    END AS avg_otw_lmh_hours,

    ar.lmh_cnt_0_6,    ar.lmh_cnt_6_12,    ar.lmh_cnt_12_18,
    ar.lmh_cnt_18_24,  ar.lmh_cnt_24_36,  ar.lmh_cnt_36_48,
    ar.lmh_cnt_48_72,  ar.lmh_cnt_72_96,  ar.lmh_cnt_96_120,
    ar.lmh_cnt_120_144,ar.lmh_cnt_144_168,ar.lmh_cnt_168_192,
    ar.lmh_cnt_192_216,ar.lmh_cnt_216_240,ar.lmh_cnt_240_264,
    ar.lmh_cnt_264_288,ar.lmh_cnt_288_312,ar.lmh_cnt_312_336,
    ar.lmh_cnt_336_360,ar.lmh_cnt_360_384,ar.lmh_cnt_384_408,
    ar.lmh_cnt_408_432,ar.lmh_cnt_432_456,ar.lmh_cnt_456_480,
    ar.lmh_cnt_480_plus
  FROM aggregated_raw ar
),

hub_metrics AS (
  SELECT
    hmb.*,
    AVG(hmb.avg_otw_lmh_hours) OVER (
      PARTITION BY hmb.delivery_hub_id
      ORDER BY hmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_lmh_hours
  FROM hub_metrics_base hmb
),

/*----------------------------------------------------------
  6) Zone-level totals (OSD + 3PL combined into OSD)
----------------------------------------------------------*/
zone_agg_raw AS (
  SELECT
    ar.order_date,
    CASE
      WHEN ar.delivery_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE ar.delivery_zone_type
    END AS delivery_zone_type,

    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.valid_otw_lmh_count)    AS valid_otw_lmh_count,
    SUM(ar.sum_otw_lmh_hours)      AS sum_otw_lmh_hours,

    SUM(ar.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(ar.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(ar.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(ar.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(ar.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(ar.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(ar.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(ar.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(ar.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(ar.lmh_cnt_120_144)AS lmh_cnt_120_144,
    SUM(ar.lmh_cnt_144_168)AS lmh_cnt_144_168,
    SUM(ar.lmh_cnt_168_192)AS lmh_cnt_168_192,
    SUM(ar.lmh_cnt_192_216)AS lmh_cnt_192_216,
    SUM(ar.lmh_cnt_216_240)AS lmh_cnt_216_240,
    SUM(ar.lmh_cnt_240_264)AS lmh_cnt_240_264,
    SUM(ar.lmh_cnt_264_288)AS lmh_cnt_264_288,
    SUM(ar.lmh_cnt_288_312)AS lmh_cnt_288_312,
    SUM(ar.lmh_cnt_312_336)AS lmh_cnt_312_336,
    SUM(ar.lmh_cnt_336_360)AS lmh_cnt_336_360,
    SUM(ar.lmh_cnt_360_384)AS lmh_cnt_360_384,
    SUM(ar.lmh_cnt_384_408)AS lmh_cnt_384_408,
    SUM(ar.lmh_cnt_408_432)AS lmh_cnt_408_432,
    SUM(ar.lmh_cnt_432_456)AS lmh_cnt_432_456,
    SUM(ar.lmh_cnt_456_480)AS lmh_cnt_456_480,
    SUM(ar.lmh_cnt_480_plus)AS lmh_cnt_480_plus
  FROM aggregated_raw ar
  GROUP BY
    ar.order_date,
    CASE
      WHEN ar.delivery_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE ar.delivery_zone_type
    END
),

zone_metrics_base AS (
  SELECT
    z.order_date,
    NULL::integer AS delivery_hub_id,
    CASE
      WHEN z.delivery_zone_type = 'ISD' THEN 'ISD Total'
      WHEN z.delivery_zone_type = 'SUB' THEN 'SUB Total'
      WHEN z.delivery_zone_type = 'OSD' THEN 'OSD Total'
      ELSE z.delivery_zone_type || ' Total'
    END AS delivery_hub_name,
    z.delivery_zone_type,
    NULL::text AS delivery_division_name,
    z.total_processed_orders,
    z.valid_otw_lmh_count,

    CASE
      WHEN z.valid_otw_lmh_count > 0
      THEN z.sum_otw_lmh_hours / z.valid_otw_lmh_count
    END AS avg_otw_lmh_hours,

    z.lmh_cnt_0_6,    z.lmh_cnt_6_12,    z.lmh_cnt_12_18,
    z.lmh_cnt_18_24,  z.lmh_cnt_24_36,  z.lmh_cnt_36_48,
    z.lmh_cnt_48_72,  z.lmh_cnt_72_96,  z.lmh_cnt_96_120,
    z.lmh_cnt_120_144,z.lmh_cnt_144_168,z.lmh_cnt_168_192,
    z.lmh_cnt_192_216,z.lmh_cnt_216_240,z.lmh_cnt_240_264,
    z.lmh_cnt_264_288,z.lmh_cnt_288_312,z.lmh_cnt_312_336,
    z.lmh_cnt_336_360,z.lmh_cnt_360_384,z.lmh_cnt_384_408,
    z.lmh_cnt_408_432,z.lmh_cnt_432_456,z.lmh_cnt_456_480,
    z.lmh_cnt_480_plus
  FROM zone_agg_raw z
),

zone_metrics AS (
  SELECT
    zmb.*,
    AVG(zmb.avg_otw_lmh_hours) OVER (
      PARTITION BY zmb.delivery_zone_type
      ORDER BY zmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_lmh_hours
  FROM zone_metrics_base zmb
),

/*----------------------------------------------------------
  7) Division-level totals
----------------------------------------------------------*/
division_agg_raw AS (
  SELECT
    ar.order_date,
    ar.delivery_zone_type,
    ar.delivery_division_name,
    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.valid_otw_lmh_count)    AS valid_otw_lmh_count,
    SUM(ar.sum_otw_lmh_hours)      AS sum_otw_lmh_hours,

    SUM(ar.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(ar.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(ar.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(ar.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(ar.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(ar.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(ar.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(ar.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(ar.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(ar.lmh_cnt_120_144)AS lmh_cnt_120_144,
    SUM(ar.lmh_cnt_144_168)AS lmh_cnt_144_168,
    SUM(ar.lmh_cnt_168_192)AS lmh_cnt_168_192,
    SUM(ar.lmh_cnt_192_216)AS lmh_cnt_192_216,
    SUM(ar.lmh_cnt_216_240)AS lmh_cnt_216_240,
    SUM(ar.lmh_cnt_240_264)AS lmh_cnt_240_264,
    SUM(ar.lmh_cnt_264_288)AS lmh_cnt_264_288,
    SUM(ar.lmh_cnt_288_312)AS lmh_cnt_288_312,
    SUM(ar.lmh_cnt_312_336)AS lmh_cnt_312_336,
    SUM(ar.lmh_cnt_336_360)AS lmh_cnt_336_360,
    SUM(ar.lmh_cnt_360_384)AS lmh_cnt_360_384,
    SUM(ar.lmh_cnt_384_408)AS lmh_cnt_384_408,
    SUM(ar.lmh_cnt_408_432)AS lmh_cnt_408_432,
    SUM(ar.lmh_cnt_432_456)AS lmh_cnt_432_456,
    SUM(ar.lmh_cnt_456_480)AS lmh_cnt_456_480,
    SUM(ar.lmh_cnt_480_plus)AS lmh_cnt_480_plus
  FROM aggregated_raw ar
  GROUP BY
    ar.order_date,
    ar.delivery_zone_type,
    ar.delivery_division_name
),

division_metrics_base AS (
  SELECT
    d.order_date,
    NULL::integer AS delivery_hub_id,
    d.delivery_division_name || ' Total' AS delivery_hub_name,
    d.delivery_zone_type,
    d.delivery_division_name,
    d.total_processed_orders,
    d.valid_otw_lmh_count,

    CASE
      WHEN d.valid_otw_lmh_count > 0
      THEN d.sum_otw_lmh_hours / d.valid_otw_lmh_count
    END AS avg_otw_lmh_hours,

    d.lmh_cnt_0_6,    d.lmh_cnt_6_12,    d.lmh_cnt_12_18,
    d.lmh_cnt_18_24,  d.lmh_cnt_24_36,  d.lmh_cnt_36_48,
    d.lmh_cnt_48_72,  d.lmh_cnt_72_96,  d.lmh_cnt_96_120,
    d.lmh_cnt_120_144,d.lmh_cnt_144_168,d.lmh_cnt_168_192,
    d.lmh_cnt_192_216,d.lmh_cnt_216_240,d.lmh_cnt_240_264,
    d.lmh_cnt_264_288,d.lmh_cnt_288_312,d.lmh_cnt_312_336,
    d.lmh_cnt_336_360,d.lmh_cnt_360_384,d.lmh_cnt_384_408,
    d.lmh_cnt_408_432,d.lmh_cnt_432_456,d.lmh_cnt_456_480,
    d.lmh_cnt_480_plus
  FROM division_agg_raw d
),

division_metrics AS (
  SELECT
    dmb.*,
    AVG(dmb.avg_otw_lmh_hours) OVER (
      PARTITION BY dmb.delivery_zone_type, dmb.delivery_division_name
      ORDER BY dmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_lmh_hours
  FROM division_metrics_base dmb
),

/*----------------------------------------------------------
  8) Global totals (all zones & divisions)
----------------------------------------------------------*/
global_agg_raw AS (
  SELECT
    ar.order_date,
    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.valid_otw_lmh_count)    AS valid_otw_lmh_count,
    SUM(ar.sum_otw_lmh_hours)      AS sum_otw_lmh_hours,

    SUM(ar.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(ar.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(ar.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(ar.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(ar.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(ar.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(ar.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(ar.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(ar.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(ar.lmh_cnt_120_144)AS lmh_cnt_120_144,
    SUM(ar.lmh_cnt_144_168)AS lmh_cnt_144_168,
    SUM(ar.lmh_cnt_168_192)AS lmh_cnt_168_192,
    SUM(ar.lmh_cnt_192_216)AS lmh_cnt_192_216,
    SUM(ar.lmh_cnt_216_240)AS lmh_cnt_216_240,
    SUM(ar.lmh_cnt_240_264)AS lmh_cnt_240_264,
    SUM(ar.lmh_cnt_264_288)AS lmh_cnt_264_288,
    SUM(ar.lmh_cnt_288_312)AS lmh_cnt_288_312,
    SUM(ar.lmh_cnt_312_336)AS lmh_cnt_312_336,
    SUM(ar.lmh_cnt_336_360)AS lmh_cnt_336_360,
    SUM(ar.lmh_cnt_360_384)AS lmh_cnt_360_384,
    SUM(ar.lmh_cnt_384_408)AS lmh_cnt_384_408,
    SUM(ar.lmh_cnt_408_432)AS lmh_cnt_408_432,
    SUM(ar.lmh_cnt_432_456)AS lmh_cnt_432_456,
    SUM(ar.lmh_cnt_456_480)AS lmh_cnt_456_480,
    SUM(ar.lmh_cnt_480_plus)AS lmh_cnt_480_plus
  FROM aggregated_raw ar
  GROUP BY ar.order_date
),

global_metrics_base AS (
  SELECT
    ga.order_date,
    NULL::integer AS delivery_hub_id,
    'Global Total' AS delivery_hub_name,
    'Global' AS delivery_zone_type,
    NULL::text AS delivery_division_name,
    ga.total_processed_orders,
    ga.valid_otw_lmh_count,

    CASE
      WHEN ga.valid_otw_lmh_count > 0
      THEN ga.sum_otw_lmh_hours / ga.valid_otw_lmh_count
    END AS avg_otw_lmh_hours,

    ga.lmh_cnt_0_6,    ga.lmh_cnt_6_12,    ga.lmh_cnt_12_18,
    ga.lmh_cnt_18_24,  ga.lmh_cnt_24_36,  ga.lmh_cnt_36_48,
    ga.lmh_cnt_48_72,  ga.lmh_cnt_72_96,  ga.lmh_cnt_96_120,
    ga.lmh_cnt_120_144,ga.lmh_cnt_144_168,ga.lmh_cnt_168_192,
    ga.lmh_cnt_192_216,ga.lmh_cnt_216_240,ga.lmh_cnt_240_264,
    ga.lmh_cnt_264_288,ga.lmh_cnt_288_312,ga.lmh_cnt_312_336,
    ga.lmh_cnt_336_360,ga.lmh_cnt_360_384,ga.lmh_cnt_384_408,
    ga.lmh_cnt_408_432,ga.lmh_cnt_432_456,ga.lmh_cnt_456_480,
    ga.lmh_cnt_480_plus
  FROM global_agg_raw ga
),

global_metrics AS (
  SELECT
    gmb.*,
    AVG(gmb.avg_otw_lmh_hours) OVER (
      ORDER BY gmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_lmh_hours
  FROM global_metrics_base gmb
),

/*----------------------------------------------------------
  9) Combine hub + zone + division + global rows
----------------------------------------------------------*/
combined AS (
  SELECT * FROM hub_metrics
  UNION ALL
  SELECT * FROM zone_metrics
  UNION ALL
  SELECT * FROM division_metrics
  UNION ALL
  SELECT * FROM global_metrics
)

/*----------------------------------------------------------
  10) Final select – counts, averages, and FRACTIONS (no *100)
----------------------------------------------------------*/
SELECT
  c.order_date           AS "Order Date",
  c.delivery_hub_id      AS "Last Mile Hub ID",
  c.delivery_hub_name    AS "Last Mile Hub Name",
  c.delivery_zone_type   AS "Last Mile Zone",
  c.delivery_division_name AS "Last Mile Division",

  c.total_processed_orders AS "Total Processed Orders",
  c.valid_otw_lmh_count    AS "Total Transported",
  ROUND(c.avg_otw_lmh_hours, 2)
    AS "Avg OTW to LMH Processing Time (hrs)",

  ROUND(c.last_7_days_avg_otw_lmh_hours, 2)
    AS "Last 7 days avg OTW to LMH Processing Time (hrs)",

  /* Main aging buckets – counts */
  c.lmh_cnt_0_6   AS "OTW to LMH 6 hrs",
  c.lmh_cnt_6_12  AS "OTW to LMH 12 hrs",
  c.lmh_cnt_12_18 AS "OTW to LMH 18 hrs",
  c.lmh_cnt_18_24 AS "OTW to LMH 24 hrs",
  c.lmh_cnt_24_36 AS "OTW to LMH 36 hrs",
  c.lmh_cnt_36_48 AS "OTW to LMH 48 hrs",
  (
    c.lmh_cnt_48_72
    + c.lmh_cnt_72_96
    + c.lmh_cnt_96_120
    + c.lmh_cnt_120_144
    + c.lmh_cnt_144_168
    + c.lmh_cnt_168_192
    + c.lmh_cnt_192_216
    + c.lmh_cnt_216_240
    + c.lmh_cnt_240_264
    + c.lmh_cnt_264_288
    + c.lmh_cnt_288_312
    + c.lmh_cnt_312_336
    + c.lmh_cnt_336_360
    + c.lmh_cnt_360_384
    + c.lmh_cnt_384_408
    + c.lmh_cnt_408_432
    + c.lmh_cnt_432_456
    + c.lmh_cnt_456_480
    + c.lmh_cnt_480_plus
  ) AS "OTW to LMH 48 hrs++",

  /* Main aging buckets – FRACTIONS of total_processed_orders (0–1) */
  ROUND(c.lmh_cnt_0_6::numeric   / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 6 hrs",
  ROUND(c.lmh_cnt_6_12::numeric  / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 12 hrs",
  ROUND(c.lmh_cnt_12_18::numeric / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 18 hrs",
  ROUND(c.lmh_cnt_18_24::numeric / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 24 hrs",
  ROUND(c.lmh_cnt_24_36::numeric / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 36 hrs",
  ROUND(c.lmh_cnt_36_48::numeric / NULLIF(c.total_processed_orders, 0), 2)
    AS "% OTW to LMH 48 hrs",
  ROUND(
    (
      c.lmh_cnt_48_72
      + c.lmh_cnt_72_96
      + c.lmh_cnt_96_120
      + c.lmh_cnt_120_144
      + c.lmh_cnt_144_168
      + c.lmh_cnt_168_192
      + c.lmh_cnt_192_216
      + c.lmh_cnt_216_240
      + c.lmh_cnt_240_264
      + c.lmh_cnt_264_288
      + c.lmh_cnt_288_312
      + c.lmh_cnt_312_336
      + c.lmh_cnt_336_360
      + c.lmh_cnt_360_384
      + c.lmh_cnt_384_408
      + c.lmh_cnt_408_432
      + c.lmh_cnt_432_456
      + c.lmh_cnt_456_480
      + c.lmh_cnt_480_plus
    )::numeric / NULLIF(c.total_processed_orders, 0),
    2
  ) AS "% OTW to LMH 48 hrs++",

  /* Extended aging buckets – counts only (72–480 & 480++) */
  c.lmh_cnt_72_96   AS "OTW to LMH 72 hrs",
  c.lmh_cnt_96_120  AS "OTW to LMH 96 hrs",
  c.lmh_cnt_120_144 AS "OTW to LMH 120 hrs",
  c.lmh_cnt_144_168 AS "OTW to LMH 144 hrs",
  c.lmh_cnt_168_192 AS "OTW to LMH 168 hrs",
  c.lmh_cnt_192_216 AS "OTW to LMH 192 hrs",
  c.lmh_cnt_216_240 AS "OTW to LMH 216 hrs",
  c.lmh_cnt_240_264 AS "OTW to LMH 240 hrs",
  c.lmh_cnt_264_288 AS "OTW to LMH 264 hrs",
  c.lmh_cnt_288_312 AS "OTW to LMH 288 hrs",
  c.lmh_cnt_312_336 AS "OTW to LMH 312 hrs",
  c.lmh_cnt_336_360 AS "OTW to LMH 336 hrs",
  c.lmh_cnt_360_384 AS "OTW to LMH 360 hrs",
  c.lmh_cnt_384_408 AS "OTW to LMH 384 hrs",
  c.lmh_cnt_408_432 AS "OTW to LMH 408 hrs",
  c.lmh_cnt_432_456 AS "OTW to LMH 432 hrs",
  c.lmh_cnt_456_480 AS "OTW to LMH 456 hrs",
  c.lmh_cnt_480_plus AS "OTW to LMH 480 hrs++"

FROM combined c
ORDER BY
  c.order_date DESC,
  c.delivery_zone_type,
  c.delivery_division_name,
  c.delivery_hub_name;
