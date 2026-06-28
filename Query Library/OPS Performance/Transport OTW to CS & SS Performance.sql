/* ============================================================
   Transport Performance – OTW to CS & OTW to SS (Pickup Hub DoD)
   - Hub-wise, zone-wise, division-wise, order-date-wise (by pickup hub)
   - DoD = (sorted_at + 6h)::date  [Pickup processed date]

   - Domain: orders "handed over to transport":
       transfer_status_id IN (
         10,11,12,13,14,15,16,17,18,19,20,21,22,
         35,36,37,38,39,42,43
       )

   OTW→CS aging (hrs):
     - Start: first 10 or 35 in order_logs (on_way_cw_raw)
     - End:   earliest 11 in order_logs (first_cw_at_raw)
     - Only when first_cw_at_raw IS NOT NULL

   OTW→SS aging (hrs):
     - Applies when:
         * order NEVER touched 11 in order_logs
         * BUT touched any of 37, 39, 43 in order_logs
     - Start (NEW): earliest of 10,35,36,38,42 in order_logs (on_way_ss_raw)
         * this now captures:
           - previous flows with 10/35 → 37/39/43, and
           - flows where after 9 there is no 10/35, but 36/38/42 → 37/39/43
     - End:   earliest of 37,39,43 in order_logs (first_ss_at_raw)
     - Aging: first_ss_at_raw - on_way_ss_raw (hrs, >0 only)

   Updated Hub / Zone / Division logic:
     - 162 Keraniganj-Ati Bazar → Zone: SUB, Division: Dhaka Sub
     - 163 Narayanganj-Bandar   → Zone: SUB, Division: Dhaka Sub
     - 161 Central IB           → Zone: Central Inbound
     - 153–159 (Bhanga / Barishal / Bhairab / Sirajgonj /
               Comilla / Rangpur / Sylhet Sub Sort)
                                 → Zone: Sub Sort
     - 71 Central Sort          → Zone: Central Warehouse
     - 72 Central Return        → Zone: Central Warehouse

   NOTE: All "%" columns are FRACTIONS (0–1). Format as % in Excel/Sheets.
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
  2) Base orders: pickup hub, zone, division, order date
     DoD = (sorted_at + 6h)::date
----------------------------------------------------------*/
base AS (
  SELECT
    o.id                                     AS order_id,
    o.transfer_status_id,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date,
    ph.id                                    AS pickup_hub_id,
    ph.name                                  AS pickup_hub_name,
    hzd.zone_type                            AS pickup_zone_type,
    hzd.division_name                        AS pickup_division_name
  FROM orders o
  LEFT JOIN hubs             ph  ON ph.id = o.pickup_hub_id
  LEFT JOIN hub_zone_div_map hzd ON hzd.hub_id = ph.id
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-02 00:00:00'

    /* Handover-to-transport status set */
    AND o.transfer_status_id IN (
      10,11,12,13,14,15,16,17,18,19,20,21,22,
      35,36,37,38,39,42,43
    )
    AND o.pickup_hub_id IS NOT NULL
),

/*----------------------------------------------------------
  3) Per-order OTW→CS and OTW→SS timestamps & aging
     - OTW→CS start: first 10 or 35
     - OTW→SS start (NEW): earliest of 10,35,36,38,42
----------------------------------------------------------*/
flow AS (
  SELECT
    b.*,
    cw_stats.first_cw_at_raw,
    ss_stats.first_ss_at_raw,
    otw_cw.on_way_cw_raw,
    otw_ss.on_way_ss_raw,

    /* OTW → CS (hrs) */
    CASE
      WHEN cw_stats.first_cw_at_raw IS NOT NULL
       AND otw_cw.on_way_cw_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (cw_stats.first_cw_at_raw - otw_cw.on_way_cw_raw)
             ) / 3600.0,
           2)
    END AS otw_to_cs_hours,

    /* OTW → SS (hrs):
       - Never touched 11
       - Has SS arrival (37/39/43)
       - Start = earliest of 10,35,36,38,42 (on_way_ss_raw)
    */
    CASE
      WHEN cw_stats.first_cw_at_raw IS NULL
       AND ss_stats.first_ss_at_raw IS NOT NULL
       AND otw_ss.on_way_ss_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (ss_stats.first_ss_at_raw - otw_ss.on_way_ss_raw)
             ) / 3600.0,
           2)
    END AS otw_to_ss_hours

  FROM base b

  /* CW: earliest status 11 (if any) */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status = 11 THEN ol.created_at END)
        AS first_cw_at_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
  ) cw_stats ON TRUE

  /* SS arrival: earliest of 37,39,43 (if any) */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status IN (37,39,43) THEN ol.created_at END)
        AS first_ss_at_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
  ) ss_stats ON TRUE

  /* OTW→CS start: first 10, else 35 */
  LEFT JOIN LATERAL (
    SELECT
      ol.created_at AS on_way_cw_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
      AND (ol.current_status = 10 OR ol.current_status = 35)
    ORDER BY
      CASE WHEN ol.current_status = 10 THEN 1 ELSE 2 END,
      ol.created_at,
      ol.id
    LIMIT 1
  ) otw_cw ON TRUE

  /* OTW→SS start (NEW): earliest of 10,35,36,38,42 */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE
            WHEN ol.current_status IN (10,35,36,38,42)
            THEN ol.created_at
          END) AS on_way_ss_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
  ) otw_ss ON TRUE
),

/*----------------------------------------------------------
  4) Aggregation per pickup hub / zone / division / order_date
----------------------------------------------------------*/
aggregated_raw AS (
  SELECT
    f.order_date,
    f.pickup_hub_id,
    f.pickup_hub_name,
    f.pickup_zone_type,
    f.pickup_division_name,

    /* 1. Total processed orders (handed to transport) */
    COUNT(*) AS total_processed_orders,

    /* OTW→CS & OTW→SS counts (hrs >0 only) */
    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 0
    ) AS otw_cs_count,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 0
    ) AS otw_ss_count,

    /* Sum of hours for valid segments */
    SUM(
      CASE
        WHEN f.otw_to_cs_hours > 0 THEN f.otw_to_cs_hours
      END
    ) AS sum_otw_cs_hours,

    SUM(
      CASE
        WHEN f.otw_to_ss_hours > 0 THEN f.otw_to_ss_hours
      END
    ) AS sum_otw_ss_hours,

    /* =======================
       OTW → CS aging buckets
       ======================= */
    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 0 AND f.otw_to_cs_hours <= 3
    ) AS cs_cnt_0_3,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 3 AND f.otw_to_cs_hours <= 6
    ) AS cs_cnt_3_6,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 6 AND f.otw_to_cs_hours <= 12
    ) AS cs_cnt_6_12,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 12 AND f.otw_to_cs_hours <= 18
    ) AS cs_cnt_12_18,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 18 AND f.otw_to_cs_hours <= 24
    ) AS cs_cnt_18_24,

    /* >24 onwards, 24-hr buckets up to 480+ */
    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 24 AND f.otw_to_cs_hours <= 48
    ) AS cs_cnt_24_48,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 48 AND f.otw_to_cs_hours <= 72
    ) AS cs_cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 72 AND f.otw_to_cs_hours <= 96
    ) AS cs_cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 96 AND f.otw_to_cs_hours <= 120
    ) AS cs_cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 120 AND f.otw_to_cs_hours <= 144
    ) AS cs_cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 144 AND f.otw_to_cs_hours <= 168
    ) AS cs_cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 168 AND f.otw_to_cs_hours <= 192
    ) AS cs_cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 192 AND f.otw_to_cs_hours <= 216
    ) AS cs_cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 216 AND f.otw_to_cs_hours <= 240
    ) AS cs_cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 240 AND f.otw_to_cs_hours <= 264
    ) AS cs_cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 264 AND f.otw_to_cs_hours <= 288
    ) AS cs_cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 288 AND f.otw_to_cs_hours <= 312
    ) AS cs_cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 312 AND f.otw_to_cs_hours <= 336
    ) AS cs_cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 336 AND f.otw_to_cs_hours <= 360
    ) AS cs_cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 360 AND f.otw_to_cs_hours <= 384
    ) AS cs_cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 384 AND f.otw_to_cs_hours <= 408
    ) AS cs_cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 408 AND f.otw_to_cs_hours <= 432
    ) AS cs_cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 432 AND f.otw_to_cs_hours <= 456
    ) AS cs_cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 456 AND f.otw_to_cs_hours <= 480
    ) AS cs_cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.otw_to_cs_hours > 480
    ) AS cs_cnt_480_plus,

    /* =======================
       OTW → SS aging buckets
       ======================= */
    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 0 AND f.otw_to_ss_hours <= 3
    ) AS ss_cnt_0_3,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 3 AND f.otw_to_ss_hours <= 6
    ) AS ss_cnt_3_6,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 6 AND f.otw_to_ss_hours <= 12
    ) AS ss_cnt_6_12,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 12 AND f.otw_to_ss_hours <= 18
    ) AS ss_cnt_12_18,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 18 AND f.otw_to_ss_hours <= 24
    ) AS ss_cnt_18_24,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 24 AND f.otw_to_ss_hours <= 48
    ) AS ss_cnt_24_48,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 48 AND f.otw_to_ss_hours <= 72
    ) AS ss_cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 72 AND f.otw_to_ss_hours <= 96
    ) AS ss_cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 96 AND f.otw_to_ss_hours <= 120
    ) AS ss_cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 120 AND f.otw_to_ss_hours <= 144
    ) AS ss_cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 144 AND f.otw_to_ss_hours <= 168
    ) AS ss_cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 168 AND f.otw_to_ss_hours <= 192
    ) AS ss_cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 192 AND f.otw_to_ss_hours <= 216
    ) AS ss_cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 216 AND f.otw_to_ss_hours <= 240
    ) AS ss_cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 240 AND f.otw_to_ss_hours <= 264
    ) AS ss_cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 264 AND f.otw_to_ss_hours <= 288
    ) AS ss_cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 288 AND f.otw_to_ss_hours <= 312
    ) AS ss_cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 312 AND f.otw_to_ss_hours <= 336
    ) AS ss_cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 336 AND f.otw_to_ss_hours <= 360
    ) AS ss_cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 360 AND f.otw_to_ss_hours <= 384
    ) AS ss_cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 384 AND f.otw_to_ss_hours <= 408
    ) AS ss_cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 408 AND f.otw_to_ss_hours <= 432
    ) AS ss_cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 432 AND f.otw_to_ss_hours <= 456
    ) AS ss_cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 456 AND f.otw_to_ss_hours <= 480
    ) AS ss_cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.otw_to_ss_hours > 480
    ) AS ss_cnt_480_plus

  FROM flow f
  GROUP BY
    f.order_date,
    f.pickup_hub_id,
    f.pickup_hub_name,
    f.pickup_zone_type,
    f.pickup_division_name
),

/*----------------------------------------------------------
  5) Hub-level metrics (compute averages + rolling averages)
----------------------------------------------------------*/
hub_metrics_base AS (
  SELECT
    ar.order_date,
    ar.pickup_hub_id,
    ar.pickup_hub_name,
    ar.pickup_zone_type,
    ar.pickup_division_name,
    ar.total_processed_orders,
    ar.otw_cs_count,
    ar.otw_ss_count,

    CASE
      WHEN ar.otw_cs_count > 0
      THEN ar.sum_otw_cs_hours / ar.otw_cs_count
    END AS avg_otw_cs_hours,

    CASE
      WHEN ar.otw_ss_count > 0
      THEN ar.sum_otw_ss_hours / ar.otw_ss_count
    END AS avg_otw_ss_hours,

    ar.cs_cnt_0_3,    ar.cs_cnt_3_6,    ar.cs_cnt_6_12,
    ar.cs_cnt_12_18,  ar.cs_cnt_18_24,  ar.cs_cnt_24_48,
    ar.cs_cnt_48_72,  ar.cs_cnt_72_96,  ar.cs_cnt_96_120,
    ar.cs_cnt_120_144,ar.cs_cnt_144_168,ar.cs_cnt_168_192,
    ar.cs_cnt_192_216,ar.cs_cnt_216_240,ar.cs_cnt_240_264,
    ar.cs_cnt_264_288,ar.cs_cnt_288_312,ar.cs_cnt_312_336,
    ar.cs_cnt_336_360,ar.cs_cnt_360_384,ar.cs_cnt_384_408,
    ar.cs_cnt_408_432,ar.cs_cnt_432_456,ar.cs_cnt_456_480,
    ar.cs_cnt_480_plus,

    ar.ss_cnt_0_3,    ar.ss_cnt_3_6,    ar.ss_cnt_6_12,
    ar.ss_cnt_12_18,  ar.ss_cnt_18_24,  ar.ss_cnt_24_48,
    ar.ss_cnt_48_72,  ar.ss_cnt_72_96,  ar.ss_cnt_96_120,
    ar.ss_cnt_120_144,ar.ss_cnt_144_168,ar.ss_cnt_168_192,
    ar.ss_cnt_192_216,ar.ss_cnt_216_240,ar.ss_cnt_240_264,
    ar.ss_cnt_264_288,ar.ss_cnt_288_312,ar.ss_cnt_312_336,
    ar.ss_cnt_336_360,ar.ss_cnt_360_384,ar.ss_cnt_384_408,
    ar.ss_cnt_408_432,ar.ss_cnt_432_456,ar.ss_cnt_456_480,
    ar.ss_cnt_480_plus
  FROM aggregated_raw ar
),

hub_metrics AS (
  SELECT
    hmb.*,
    AVG(hmb.avg_otw_cs_hours) OVER (
      PARTITION BY hmb.pickup_hub_id
      ORDER BY hmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_cs_hours,

    AVG(hmb.avg_otw_ss_hours) OVER (
      PARTITION BY hmb.pickup_hub_id
      ORDER BY hmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_ss_hours
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

    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.otw_cs_count)          AS otw_cs_count,
    SUM(ar.otw_ss_count)          AS otw_ss_count,
    SUM(ar.sum_otw_cs_hours)      AS sum_otw_cs_hours,
    SUM(ar.sum_otw_ss_hours)      AS sum_otw_ss_hours,

    SUM(ar.cs_cnt_0_3)    AS cs_cnt_0_3,
    SUM(ar.cs_cnt_3_6)    AS cs_cnt_3_6,
    SUM(ar.cs_cnt_6_12)   AS cs_cnt_6_12,
    SUM(ar.cs_cnt_12_18)  AS cs_cnt_12_18,
    SUM(ar.cs_cnt_18_24)  AS cs_cnt_18_24,
    SUM(ar.cs_cnt_24_48)  AS cs_cnt_24_48,
    SUM(ar.cs_cnt_48_72)  AS cs_cnt_48_72,
    SUM(ar.cs_cnt_72_96)  AS cs_cnt_72_96,
    SUM(ar.cs_cnt_96_120) AS cs_cnt_96_120,
    SUM(ar.cs_cnt_120_144)AS cs_cnt_120_144,
    SUM(ar.cs_cnt_144_168)AS cs_cnt_144_168,
    SUM(ar.cs_cnt_168_192)AS cs_cnt_168_192,
    SUM(ar.cs_cnt_192_216)AS cs_cnt_192_216,
    SUM(ar.cs_cnt_216_240)AS cs_cnt_216_240,
    SUM(ar.cs_cnt_240_264)AS cs_cnt_240_264,
    SUM(ar.cs_cnt_264_288)AS cs_cnt_264_288,
    SUM(ar.cs_cnt_288_312)AS cs_cnt_288_312,
    SUM(ar.cs_cnt_312_336)AS cs_cnt_312_336,
    SUM(ar.cs_cnt_336_360)AS cs_cnt_336_360,
    SUM(ar.cs_cnt_360_384)AS cs_cnt_360_384,
    SUM(ar.cs_cnt_384_408)AS cs_cnt_384_408,
    SUM(ar.cs_cnt_408_432)AS cs_cnt_408_432,
    SUM(ar.cs_cnt_432_456)AS cs_cnt_432_456,
    SUM(ar.cs_cnt_456_480)AS cs_cnt_456_480,
    SUM(ar.cs_cnt_480_plus)AS cs_cnt_480_plus,

    SUM(ar.ss_cnt_0_3)    AS ss_cnt_0_3,
    SUM(ar.ss_cnt_3_6)    AS ss_cnt_3_6,
    SUM(ar.ss_cnt_6_12)   AS ss_cnt_6_12,
    SUM(ar.ss_cnt_12_18)  AS ss_cnt_12_18,
    SUM(ar.ss_cnt_18_24)  AS ss_cnt_18_24,
    SUM(ar.ss_cnt_24_48)  AS ss_cnt_24_48,
    SUM(ar.ss_cnt_48_72)  AS ss_cnt_48_72,
    SUM(ar.ss_cnt_72_96)  AS ss_cnt_72_96,
    SUM(ar.ss_cnt_96_120) AS ss_cnt_96_120,
    SUM(ar.ss_cnt_120_144)AS ss_cnt_120_144,
    SUM(ar.ss_cnt_144_168)AS ss_cnt_144_168,
    SUM(ar.ss_cnt_168_192)AS ss_cnt_168_192,
    SUM(ar.ss_cnt_192_216)AS ss_cnt_192_216,
    SUM(ar.ss_cnt_216_240)AS ss_cnt_216_240,
    SUM(ar.ss_cnt_240_264)AS ss_cnt_240_264,
    SUM(ar.ss_cnt_264_288)AS ss_cnt_264_288,
    SUM(ar.ss_cnt_288_312)AS ss_cnt_288_312,
    SUM(ar.ss_cnt_312_336)AS ss_cnt_312_336,
    SUM(ar.ss_cnt_336_360)AS ss_cnt_336_360,
    SUM(ar.ss_cnt_360_384)AS ss_cnt_360_384,
    SUM(ar.ss_cnt_384_408)AS ss_cnt_384_408,
    SUM(ar.ss_cnt_408_432)AS ss_cnt_408_432,
    SUM(ar.ss_cnt_432_456)AS ss_cnt_432_456,
    SUM(ar.ss_cnt_456_480)AS ss_cnt_456_480,
    SUM(ar.ss_cnt_480_plus)AS ss_cnt_480_plus

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
      WHEN z.pickup_zone_type = 'OSD' THEN 'OSD Total'
      ELSE z.pickup_zone_type || ' Total'
    END AS pickup_hub_name,
    z.pickup_zone_type,
    NULL::text AS pickup_division_name,
    z.total_processed_orders,
    z.otw_cs_count,
    z.otw_ss_count,

    CASE
      WHEN z.otw_cs_count > 0
      THEN z.sum_otw_cs_hours / z.otw_cs_count
    END AS avg_otw_cs_hours,

    CASE
      WHEN z.otw_ss_count > 0
      THEN z.sum_otw_ss_hours / z.otw_ss_count
    END AS avg_otw_ss_hours,

    z.cs_cnt_0_3,    z.cs_cnt_3_6,    z.cs_cnt_6_12,
    z.cs_cnt_12_18,  z.cs_cnt_18_24,  z.cs_cnt_24_48,
    z.cs_cnt_48_72,  z.cs_cnt_72_96,  z.cs_cnt_96_120,
    z.cs_cnt_120_144,z.cs_cnt_144_168,z.cs_cnt_168_192,
    z.cs_cnt_192_216,z.cs_cnt_216_240,z.cs_cnt_240_264,
    z.cs_cnt_264_288,z.cs_cnt_288_312,z.cs_cnt_312_336,
    z.cs_cnt_336_360,z.cs_cnt_360_384,z.cs_cnt_384_408,
    z.cs_cnt_408_432,z.cs_cnt_432_456,z.cs_cnt_456_480,
    z.cs_cnt_480_plus,

    z.ss_cnt_0_3,    z.ss_cnt_3_6,    z.ss_cnt_6_12,
    z.ss_cnt_12_18,  z.ss_cnt_18_24,  z.ss_cnt_24_48,
    z.ss_cnt_48_72,  z.ss_cnt_72_96,  z.ss_cnt_96_120,
    z.ss_cnt_120_144,z.ss_cnt_144_168,z.ss_cnt_168_192,
    z.ss_cnt_192_216,z.ss_cnt_216_240,z.ss_cnt_240_264,
    z.ss_cnt_264_288,z.ss_cnt_288_312,z.ss_cnt_312_336,
    z.ss_cnt_336_360,z.ss_cnt_360_384,z.ss_cnt_384_408,
    z.ss_cnt_408_432,z.ss_cnt_432_456,z.ss_cnt_456_480,
    z.ss_cnt_480_plus
  FROM zone_agg_raw z
),

zone_metrics AS (
  SELECT
    zmb.*,
    AVG(zmb.avg_otw_cs_hours) OVER (
      PARTITION BY zmb.pickup_zone_type
      ORDER BY zmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_cs_hours,

    AVG(zmb.avg_otw_ss_hours) OVER (
      PARTITION BY zmb.pickup_zone_type
      ORDER BY zmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_ss_hours
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
    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.otw_cs_count)          AS otw_cs_count,
    SUM(ar.otw_ss_count)          AS otw_ss_count,
    SUM(ar.sum_otw_cs_hours)      AS sum_otw_cs_hours,
    SUM(ar.sum_otw_ss_hours)      AS sum_otw_ss_hours,

    SUM(ar.cs_cnt_0_3)    AS cs_cnt_0_3,
    SUM(ar.cs_cnt_3_6)    AS cs_cnt_3_6,
    SUM(ar.cs_cnt_6_12)   AS cs_cnt_6_12,
    SUM(ar.cs_cnt_12_18)  AS cs_cnt_12_18,
    SUM(ar.cs_cnt_18_24)  AS cs_cnt_18_24,
    SUM(ar.cs_cnt_24_48)  AS cs_cnt_24_48,
    SUM(ar.cs_cnt_48_72)  AS cs_cnt_48_72,
    SUM(ar.cs_cnt_72_96)  AS cs_cnt_72_96,
    SUM(ar.cs_cnt_96_120) AS cs_cnt_96_120,
    SUM(ar.cs_cnt_120_144)AS cs_cnt_120_144,
    SUM(ar.cs_cnt_144_168)AS cs_cnt_144_168,
    SUM(ar.cs_cnt_168_192)AS cs_cnt_168_192,
    SUM(ar.cs_cnt_192_216)AS cs_cnt_192_216,
    SUM(ar.cs_cnt_216_240)AS cs_cnt_216_240,
    SUM(ar.cs_cnt_240_264)AS cs_cnt_240_264,
    SUM(ar.cs_cnt_264_288)AS cs_cnt_264_288,
    SUM(ar.cs_cnt_288_312)AS cs_cnt_288_312,
    SUM(ar.cs_cnt_312_336)AS cs_cnt_312_336,
    SUM(ar.cs_cnt_336_360)AS cs_cnt_336_360,
    SUM(ar.cs_cnt_360_384)AS cs_cnt_360_384,
    SUM(ar.cs_cnt_384_408)AS cs_cnt_384_408,
    SUM(ar.cs_cnt_408_432)AS cs_cnt_408_432,
    SUM(ar.cs_cnt_432_456)AS cs_cnt_432_456,
    SUM(ar.cs_cnt_456_480)AS cs_cnt_456_480,
    SUM(ar.cs_cnt_480_plus)AS cs_cnt_480_plus,

    SUM(ar.ss_cnt_0_3)    AS ss_cnt_0_3,
    SUM(ar.ss_cnt_3_6)    AS ss_cnt_3_6,
    SUM(ar.ss_cnt_6_12)   AS ss_cnt_6_12,
    SUM(ar.ss_cnt_12_18)  AS ss_cnt_12_18,
    SUM(ar.ss_cnt_18_24)  AS ss_cnt_18_24,
    SUM(ar.ss_cnt_24_48)  AS ss_cnt_24_48,
    SUM(ar.ss_cnt_48_72)  AS ss_cnt_48_72,
    SUM(ar.ss_cnt_72_96)  AS ss_cnt_72_96,
    SUM(ar.ss_cnt_96_120) AS ss_cnt_96_120,
    SUM(ar.ss_cnt_120_144)AS ss_cnt_120_144,
    SUM(ar.ss_cnt_144_168)AS ss_cnt_144_168,
    SUM(ar.ss_cnt_168_192)AS ss_cnt_168_192,
    SUM(ar.ss_cnt_192_216)AS ss_cnt_192_216,
    SUM(ar.ss_cnt_216_240)AS ss_cnt_216_240,
    SUM(ar.ss_cnt_240_264)AS ss_cnt_240_264,
    SUM(ar.ss_cnt_264_288)AS ss_cnt_264_288,
    SUM(ar.ss_cnt_288_312)AS ss_cnt_288_312,
    SUM(ar.ss_cnt_312_336)AS ss_cnt_312_336,
    SUM(ar.ss_cnt_336_360)AS ss_cnt_336_360,
    SUM(ar.ss_cnt_360_384)AS ss_cnt_360_384,
    SUM(ar.ss_cnt_384_408)AS ss_cnt_384_408,
    SUM(ar.ss_cnt_408_432)AS ss_cnt_408_432,
    SUM(ar.ss_cnt_432_456)AS ss_cnt_432_456,
    SUM(ar.ss_cnt_456_480)AS ss_cnt_456_480,
    SUM(ar.ss_cnt_480_plus)AS ss_cnt_480_plus

  FROM aggregated_raw ar
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
    d.total_processed_orders,
    d.otw_cs_count,
    d.otw_ss_count,

    CASE
      WHEN d.otw_cs_count > 0
      THEN d.sum_otw_cs_hours / d.otw_cs_count
    END AS avg_otw_cs_hours,

    CASE
      WHEN d.otw_ss_count > 0
      THEN d.sum_otw_ss_hours / d.otw_ss_count
    END AS avg_otw_ss_hours,

    d.cs_cnt_0_3,    d.cs_cnt_3_6,    d.cs_cnt_6_12,
    d.cs_cnt_12_18,  d.cs_cnt_18_24,  d.cs_cnt_24_48,
    d.cs_cnt_48_72,  d.cs_cnt_72_96,  d.cs_cnt_96_120,
    d.cs_cnt_120_144,d.cs_cnt_144_168,d.cs_cnt_168_192,
    d.cs_cnt_192_216,d.cs_cnt_216_240,d.cs_cnt_240_264,
    d.cs_cnt_264_288,d.cs_cnt_288_312,d.cs_cnt_312_336,
    d.cs_cnt_336_360,d.cs_cnt_360_384,d.cs_cnt_384_408,
    d.cs_cnt_408_432,d.cs_cnt_432_456,d.cs_cnt_456_480,
    d.cs_cnt_480_plus,

    d.ss_cnt_0_3,    d.ss_cnt_3_6,    d.ss_cnt_6_12,
    d.ss_cnt_12_18,  d.ss_cnt_18_24,  d.ss_cnt_24_48,
    d.ss_cnt_48_72,  d.ss_cnt_72_96,  d.ss_cnt_96_120,
    d.ss_cnt_120_144,d.ss_cnt_144_168,d.ss_cnt_168_192,
    d.ss_cnt_192_216,d.ss_cnt_216_240,d.ss_cnt_240_264,
    d.ss_cnt_264_288,d.ss_cnt_288_312,d.ss_cnt_312_336,
    d.ss_cnt_336_360,d.ss_cnt_360_384,d.ss_cnt_384_408,
    d.ss_cnt_408_432,d.ss_cnt_432_456,d.ss_cnt_456_480,
    d.ss_cnt_480_plus
  FROM division_agg_raw d
),

division_metrics AS (
  SELECT
    dmb.*,
    AVG(dmb.avg_otw_cs_hours) OVER (
      PARTITION BY dmb.pickup_zone_type, dmb.pickup_division_name
      ORDER BY dmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_cs_hours,

    AVG(dmb.avg_otw_ss_hours) OVER (
      PARTITION BY dmb.pickup_zone_type, dmb.pickup_division_name
      ORDER BY dmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_ss_hours
  FROM division_metrics_base dmb
),

/*----------------------------------------------------------
  8) Global totals (all zones & divisions)
----------------------------------------------------------*/
global_agg_raw AS (
  SELECT
    ar.order_date,
    SUM(ar.total_processed_orders) AS total_processed_orders,
    SUM(ar.otw_cs_count)          AS otw_cs_count,
    SUM(ar.otw_ss_count)          AS otw_ss_count,
    SUM(ar.sum_otw_cs_hours)      AS sum_otw_cs_hours,
    SUM(ar.sum_otw_ss_hours)      AS sum_otw_ss_hours,

    SUM(ar.cs_cnt_0_3)    AS cs_cnt_0_3,
    SUM(ar.cs_cnt_3_6)    AS cs_cnt_3_6,
    SUM(ar.cs_cnt_6_12)   AS cs_cnt_6_12,
    SUM(ar.cs_cnt_12_18)  AS cs_cnt_12_18,
    SUM(ar.cs_cnt_18_24)  AS cs_cnt_18_24,
    SUM(ar.cs_cnt_24_48)  AS cs_cnt_24_48,
    SUM(ar.cs_cnt_48_72)  AS cs_cnt_48_72,
    SUM(ar.cs_cnt_72_96)  AS cs_cnt_72_96,
    SUM(ar.cs_cnt_96_120) AS cs_cnt_96_120,
    SUM(ar.cs_cnt_120_144)AS cs_cnt_120_144,
    SUM(ar.cs_cnt_144_168)AS cs_cnt_144_168,
    SUM(ar.cs_cnt_168_192)AS cs_cnt_168_192,
    SUM(ar.cs_cnt_192_216)AS cs_cnt_192_216,
    SUM(ar.cs_cnt_216_240)AS cs_cnt_216_240,
    SUM(ar.cs_cnt_240_264)AS cs_cnt_240_264,
    SUM(ar.cs_cnt_264_288)AS cs_cnt_264_288,
    SUM(ar.cs_cnt_288_312)AS cs_cnt_288_312,
    SUM(ar.cs_cnt_312_336)AS cs_cnt_312_336,
    SUM(ar.cs_cnt_336_360)AS cs_cnt_336_360,
    SUM(ar.cs_cnt_360_384)AS cs_cnt_360_384,
    SUM(ar.cs_cnt_384_408)AS cs_cnt_384_408,
    SUM(ar.cs_cnt_408_432)AS cs_cnt_408_432,
    SUM(ar.cs_cnt_432_456)AS cs_cnt_432_456,
    SUM(ar.cs_cnt_456_480)AS cs_cnt_456_480,
    SUM(ar.cs_cnt_480_plus)AS cs_cnt_480_plus,

    SUM(ar.ss_cnt_0_3)    AS ss_cnt_0_3,
    SUM(ar.ss_cnt_3_6)    AS ss_cnt_3_6,
    SUM(ar.ss_cnt_6_12)   AS ss_cnt_6_12,
    SUM(ar.ss_cnt_12_18)  AS ss_cnt_12_18,
    SUM(ar.ss_cnt_18_24)  AS ss_cnt_18_24,
    SUM(ar.ss_cnt_24_48)  AS ss_cnt_24_48,
    SUM(ar.ss_cnt_48_72)  AS ss_cnt_48_72,
    SUM(ar.ss_cnt_72_96)  AS ss_cnt_72_96,
    SUM(ar.ss_cnt_96_120) AS ss_cnt_96_120,
    SUM(ar.ss_cnt_120_144)AS ss_cnt_120_144,
    SUM(ar.ss_cnt_144_168)AS ss_cnt_144_168,
    SUM(ar.ss_cnt_168_192)AS ss_cnt_168_192,
    SUM(ar.ss_cnt_192_216)AS ss_cnt_192_216,
    SUM(ar.ss_cnt_216_240)AS ss_cnt_216_240,
    SUM(ar.ss_cnt_240_264)AS ss_cnt_240_264,
    SUM(ar.ss_cnt_264_288)AS ss_cnt_264_288,
    SUM(ar.ss_cnt_288_312)AS ss_cnt_288_312,
    SUM(ar.ss_cnt_312_336)AS ss_cnt_312_336,
    SUM(ar.ss_cnt_336_360)AS ss_cnt_336_360,
    SUM(ar.ss_cnt_360_384)AS ss_cnt_360_384,
    SUM(ar.ss_cnt_384_408)AS ss_cnt_384_408,
    SUM(ar.ss_cnt_408_432)AS ss_cnt_408_432,
    SUM(ar.ss_cnt_432_456)AS ss_cnt_432_456,
    SUM(ar.ss_cnt_456_480)AS ss_cnt_456_480,
    SUM(ar.ss_cnt_480_plus)AS ss_cnt_480_plus

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
    ga.total_processed_orders,
    ga.otw_cs_count,
    ga.otw_ss_count,

    CASE
      WHEN ga.otw_cs_count > 0
      THEN ga.sum_otw_cs_hours / ga.otw_cs_count
    END AS avg_otw_cs_hours,

    CASE
      WHEN ga.otw_ss_count > 0
      THEN ga.sum_otw_ss_hours / ga.otw_ss_count
    END AS avg_otw_ss_hours,

    ga.cs_cnt_0_3,    ga.cs_cnt_3_6,    ga.cs_cnt_6_12,
    ga.cs_cnt_12_18,  ga.cs_cnt_18_24,  ga.cs_cnt_24_48,
    ga.cs_cnt_48_72,  ga.cs_cnt_72_96,  ga.cs_cnt_96_120,
    ga.cs_cnt_120_144,ga.cs_cnt_144_168,ga.cs_cnt_168_192,
    ga.cs_cnt_192_216,ga.cs_cnt_216_240,ga.cs_cnt_240_264,
    ga.cs_cnt_264_288,ga.cs_cnt_288_312,ga.cs_cnt_312_336,
    ga.cs_cnt_336_360,ga.cs_cnt_360_384,ga.cs_cnt_384_408,
    ga.cs_cnt_408_432,ga.cs_cnt_432_456,ga.cs_cnt_456_480,
    ga.cs_cnt_480_plus,

    ga.ss_cnt_0_3,    ga.ss_cnt_3_6,    ga.ss_cnt_6_12,
    ga.ss_cnt_12_18,  ga.ss_cnt_18_24,  ga.ss_cnt_24_48,
    ga.ss_cnt_48_72,  ga.ss_cnt_72_96,  ga.ss_cnt_96_120,
    ga.ss_cnt_120_144,ga.ss_cnt_144_168,ga.ss_cnt_168_192,
    ga.ss_cnt_192_216,ga.ss_cnt_216_240,ga.ss_cnt_240_264,
    ga.ss_cnt_264_288,ga.ss_cnt_288_312,ga.ss_cnt_312_336,
    ga.ss_cnt_336_360,ga.ss_cnt_360_384,ga.ss_cnt_384_408,
    ga.ss_cnt_408_432,ga.ss_cnt_432_456,ga.ss_cnt_456_480,
    ga.ss_cnt_480_plus
  FROM global_agg_raw ga
),

global_metrics AS (
  SELECT
    gmb.*,
    AVG(gmb.avg_otw_cs_hours) OVER (
      ORDER BY gmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_cs_hours,

    AVG(gmb.avg_otw_ss_hours) OVER (
      ORDER BY gmb.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_days_avg_otw_ss_hours
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
  c.order_date        AS "Order Date",
  c.pickup_hub_id     AS "Pickup Hub ID",
  c.pickup_hub_name   AS "Pickup Hub Name",
  c.pickup_zone_type  AS "Pickup Zone",
  c.pickup_division_name AS "Pickup Division",

  c.total_processed_orders AS "Total Processed Orders",
  c.otw_cs_count           AS "OTW to CS Count",
  c.otw_ss_count           AS "OTW to SS Count",

  ROUND(c.avg_otw_cs_hours, 2)
    AS "Avg OTW to CS Processing Time (hrs)",

  ROUND(c.last_7_days_avg_otw_cs_hours, 2)
    AS "Last 7 days avg OTW to CS Processing Time (hrs)",

  ROUND(c.avg_otw_ss_hours, 2)
    AS "Avg OTW to SS Processing Time (hrs)",

  ROUND(c.last_7_days_avg_otw_ss_hours, 2)
    AS "Last 7 days avg OTW to SS Processing Time (hrs)",

  /* ========== OTW → CS buckets (counts) ========== */
  c.cs_cnt_0_3   AS "OTW to CS 3 hrs",
  c.cs_cnt_3_6   AS "OTW to CS 6 hrs",
  c.cs_cnt_6_12  AS "OTW to CS 12 hrs",
  c.cs_cnt_12_18 AS "OTW to CS 18 hrs",
  c.cs_cnt_18_24 AS "OTW to CS 24 hrs",
  (
    c.cs_cnt_24_48
    + c.cs_cnt_48_72
    + c.cs_cnt_72_96
    + c.cs_cnt_96_120
    + c.cs_cnt_120_144
    + c.cs_cnt_144_168
    + c.cs_cnt_168_192
    + c.cs_cnt_192_216
    + c.cs_cnt_216_240
    + c.cs_cnt_240_264
    + c.cs_cnt_264_288
    + c.cs_cnt_288_312
    + c.cs_cnt_312_336
    + c.cs_cnt_336_360
    + c.cs_cnt_360_384
    + c.cs_cnt_384_408
    + c.cs_cnt_408_432
    + c.cs_cnt_432_456
    + c.cs_cnt_456_480
    + c.cs_cnt_480_plus
  ) AS "OTW to CS 24 hrs++",

  /* OTW → CS FRACTIONS (0–1, denominator = otw_cs_count) */
  ROUND(c.cs_cnt_0_3   / NULLIF(c.otw_cs_count, 0), 2)
    AS "% OTW to CS 3 hrs",
  ROUND(c.cs_cnt_3_6   / NULLIF(c.otw_cs_count, 0), 2)
    AS "% OTW to CS 6 hrs",
  ROUND(c.cs_cnt_6_12  / NULLIF(c.otw_cs_count, 0), 2)
    AS "% OTW to CS 12 hrs",
  ROUND(c.cs_cnt_12_18 / NULLIF(c.otw_cs_count, 0), 2)
    AS "% OTW to CS 18 hrs",
  ROUND(c.cs_cnt_18_24 / NULLIF(c.otw_cs_count, 0), 2)
    AS "% OTW to CS 24 hrs",
  ROUND(
    (
      c.cs_cnt_24_48
      + c.cs_cnt_48_72
      + c.cs_cnt_72_96
      + c.cs_cnt_96_120
      + c.cs_cnt_120_144
      + c.cs_cnt_144_168
      + c.cs_cnt_168_192
      + c.cs_cnt_192_216
      + c.cs_cnt_216_240
      + c.cs_cnt_240_264
      + c.cs_cnt_264_288
      + c.cs_cnt_288_312
      + c.cs_cnt_312_336
      + c.cs_cnt_336_360
      + c.cs_cnt_360_384
      + c.cs_cnt_384_408
      + c.cs_cnt_408_432
      + c.cs_cnt_432_456
      + c.cs_cnt_456_480
      + c.cs_cnt_480_plus
    ) / NULLIF(c.otw_cs_count, 0),
    2
  ) AS "% OTW to CS 24 hrs++",

  /* OTW → CS extended buckets (counts only) */
  c.cs_cnt_48_72   AS "OTW to CS 48 hrs",
  c.cs_cnt_72_96   AS "OTW to CS 72 hrs",
  c.cs_cnt_96_120  AS "OTW to CS 96 hrs",
  c.cs_cnt_120_144 AS "OTW to CS 120 hrs",
  c.cs_cnt_144_168 AS "OTW to CS 144 hrs",
  c.cs_cnt_168_192 AS "OTW to CS 168 hrs",
  c.cs_cnt_192_216 AS "OTW to CS 192 hrs",
  c.cs_cnt_216_240 AS "OTW to CS 216 hrs",
  c.cs_cnt_240_264 AS "OTW to CS 240 hrs",
  c.cs_cnt_264_288 AS "OTW to CS 264 hrs",
  c.cs_cnt_288_312 AS "OTW to CS 288 hrs",
  c.cs_cnt_312_336 AS "OTW to CS 312 hrs",
  c.cs_cnt_336_360 AS "OTW to CS 336 hrs",
  c.cs_cnt_360_384 AS "OTW to CS 360 hrs",
  c.cs_cnt_384_408 AS "OTW to CS 384 hrs",
  c.cs_cnt_408_432 AS "OTW to CS 408 hrs",
  c.cs_cnt_432_456 AS "OTW to CS 432 hrs",
  c.cs_cnt_456_480 AS "OTW to CS 456 hrs",
  c.cs_cnt_480_plus AS "OTW to CS 480 hrs++",

  /* ========== OTW → SS buckets (counts) ========== */
  c.ss_cnt_0_3   AS "OTW to SS 3 hrs",
  c.ss_cnt_3_6   AS "OTW to SS 6 hrs",
  c.ss_cnt_6_12  AS "OTW to SS 12 hrs",
  c.ss_cnt_12_18 AS "OTW to SS 18 hrs",
  c.ss_cnt_18_24 AS "OTW to SS 24 hrs",
  (
    c.ss_cnt_24_48
    + c.ss_cnt_48_72
    + c.ss_cnt_72_96
    + c.ss_cnt_96_120
    + c.ss_cnt_120_144
    + c.ss_cnt_144_168
    + c.ss_cnt_168_192
    + c.ss_cnt_192_216
    + c.ss_cnt_216_240
    + c.ss_cnt_240_264
    + c.ss_cnt_264_288
    + c.ss_cnt_288_312
    + c.ss_cnt_312_336
    + c.ss_cnt_336_360
    + c.ss_cnt_360_384
    + c.ss_cnt_384_408
    + c.ss_cnt_408_432
    + c.ss_cnt_432_456
    + c.ss_cnt_456_480
    + c.ss_cnt_480_plus
  ) AS "OTW to SS 24 hrs++",

  /* OTW → SS FRACTIONS (0–1, denominator = otw_ss_count) */
  ROUND(c.ss_cnt_0_3   / NULLIF(c.otw_ss_count, 0), 2)
    AS "% OTW to SS 3 hrs",
  ROUND(c.ss_cnt_3_6   / NULLIF(c.otw_ss_count, 0), 2)
    AS "% OTW to SS 6 hrs",
  ROUND(c.ss_cnt_6_12  / NULLIF(c.otw_ss_count, 0), 2)
    AS "% OTW to SS 12 hrs",
  ROUND(c.ss_cnt_12_18 / NULLIF(c.otw_ss_count, 0), 2)
    AS "% OTW to SS 18 hrs",
  ROUND(c.ss_cnt_18_24 / NULLIF(c.otw_ss_count, 0), 2)
    AS "% OTW to SS 24 hrs",
  ROUND(
    (
      c.ss_cnt_24_48
      + c.ss_cnt_48_72
      + c.ss_cnt_72_96
      + c.ss_cnt_96_120
      + c.ss_cnt_120_144
      + c.ss_cnt_144_168
      + c.ss_cnt_168_192
      + c.ss_cnt_192_216
      + c.ss_cnt_216_240
      + c.ss_cnt_240_264
      + c.ss_cnt_264_288
      + c.ss_cnt_288_312
      + c.ss_cnt_312_336
      + c.ss_cnt_336_360
      + c.ss_cnt_360_384
      + c.ss_cnt_384_408
      + c.ss_cnt_408_432
      + c.ss_cnt_432_456
      + c.ss_cnt_456_480
      + c.ss_cnt_480_plus
    ) / NULLIF(c.otw_ss_count, 0),
    2
  ) AS "% OTW to SS 24 hrs++",

  /* OTW → SS extended buckets (counts only) */
  c.ss_cnt_48_72   AS "OTW to SS 48 hrs",
  c.ss_cnt_72_96   AS "OTW to SS 72 hrs",
  c.ss_cnt_96_120  AS "OTW to SS 96 hrs",
  c.ss_cnt_120_144 AS "OTW to SS 120 hrs",
  c.ss_cnt_144_168 AS "OTW to SS 144 hrs",
  c.ss_cnt_168_192 AS "OTW to SS 168 hrs",
  c.ss_cnt_192_216 AS "OTW to SS 192 hrs",
  c.ss_cnt_216_240 AS "OTW to SS 216 hrs",
  c.ss_cnt_240_264 AS "OTW to SS 240 hrs",
  c.ss_cnt_264_288 AS "OTW to SS 264 hrs",
  c.ss_cnt_288_312 AS "OTW to SS 288 hrs",
  c.ss_cnt_312_336 AS "OTW to SS 312 hrs",
  c.ss_cnt_336_360 AS "OTW to SS 336 hrs",
  c.ss_cnt_360_384 AS "OTW to SS 360 hrs",
  c.ss_cnt_384_408 AS "OTW to SS 384 hrs",
  c.ss_cnt_408_432 AS "OTW to SS 408 hrs",
  c.ss_cnt_432_456 AS "OTW to SS 432 hrs",
  c.ss_cnt_456_480 AS "OTW to SS 456 hrs",
  c.ss_cnt_480_plus AS "OTW to SS 480 hrs++"

FROM combined c
ORDER BY
  c.order_date DESC,
  c.pickup_zone_type,
  c.pickup_division_name,
  c.pickup_hub_name;
