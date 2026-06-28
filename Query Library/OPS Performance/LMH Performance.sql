
/* ============================================================
   Last Mile Hub DoD Performance – Daily Summary (with Zone,
   Division, Zone Totals, Division Totals & Global Totals)
   - Row types:
       * Hub rows: Order Date + LMH + Zone + Division
       * Zone totals: ISD Total, SUB Total, OSD Total (OSD + 3PL)
       * Division totals: Barisal Total, CTG Total, Dhaka ISD Total,
                         Dhaka OSD Total, Dhaka Sub Total, Khulna Total,
                         Mymensingh Total, Rajshahi Total, Rangpur Total,
                         Sylhet Total, 3PL Total
       * Also: new zone types Central Warehouse, Central Inbound, Sub Sort
       * Global Total: all LMH combined
   - Time reference:
       Order Date = (sorted_at + INTERVAL '6 hours')::date
   - Status set in ORDERS (overall LMH set):
       13,14,15,16,17,18,19,20,21,22

   NOTE:
     - All "%" columns are FRACTIONS (0–1). Format as % in Excel/Sheets.
============================================================ */

WITH
/*----------------------------------------------------------
  1) Hub → Zone + Division map
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,

    /* Zone type:
       ISD, SUB, 3PL, OSD,
       Central Warehouse (71,72),
       Central Inbound (161),
       Sub Sort (153–159)
    */
    CASE
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id = 161 THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort'
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type,

    /* Division name (as provided) */
    CASE
      WHEN h.id IN (10) THEN '3PL'

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
  2) Base orders: last mile hub, zone, division, order date
     - Overall status set: 13–22
     - Time base: sorted_at + 6h
----------------------------------------------------------*/
base AS (
  SELECT
    o.id                                     AS order_id,
    o.transfer_status_id,
    o.transfer_status_updated_at,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date,
    dh.id                                    AS delivery_hub_id,
    dh.name                                  AS delivery_hub_name,
    dhz.zone_type                            AS delivery_zone_type,
    dhz.division_name                        AS delivery_division_name
  FROM public.orders o
  LEFT JOIN public.hubs   dh  ON dh.id = o.delivery_hub_id
  LEFT JOIN hub_zone_map  dhz ON dhz.hub_id = dh.id
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-02 00:00:00'
    AND o.transfer_status_id IN (
      13,14,15,16,17,18,19,20,21,22
    )
),

/*----------------------------------------------------------
  3) Log-derived LMH, attempts, holds, aging (per order)
----------------------------------------------------------*/
flow AS (
  SELECT
    b.*,
    la.lmh_logs_raw,
    la.attempt_count,
    la.hold_count_unique_days      AS hold_count_non_system,
    la.last_hold_at_raw,
    atts.attempt_1_at_raw,
    hold_chain.last_hold_finished_at_raw,

    /* LMH → Terminal aging (hrs) – only for terminal statuses */
    CASE
      WHEN la.lmh_logs_raw IS NOT NULL
       AND b.transfer_status_updated_at IS NOT NULL
       AND b.transfer_status_id IN (15,17,18,19,20,21,22)
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (b.transfer_status_updated_at - la.lmh_logs_raw)
             ) / 3600.0,
           2)
    END AS lmh_to_terminal_hours,

    /* 1st Attempt Aging: 1st Attempt - LMH */
    CASE
      WHEN la.lmh_logs_raw IS NOT NULL
       AND atts.attempt_1_at_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (atts.attempt_1_at_raw - la.lmh_logs_raw)
             ) / 3600.0,
           2)
    END AS first_attempt_aging_hours,

    /* Hold Aging: Last Hold Finished - LMH */
    CASE
      WHEN la.lmh_logs_raw IS NOT NULL
       AND hold_chain.last_hold_finished_at_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(
               EPOCH FROM (hold_chain.last_hold_finished_at_raw - la.lmh_logs_raw)
             ) / 3600.0,
           2)
    END AS hold_aging_hours

  FROM base b

  /* LMH logs, attempts, holds per order */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status = 13 THEN ol.created_at END)
        AS lmh_logs_raw,
      COUNT(*) FILTER (WHERE ol.current_status = 14)
        AS attempt_count,
      COUNT(DISTINCT ol.created_at::date)
        FILTER (WHERE ol.current_status = 16)
        AS hold_count_unique_days,
      MIN(CASE WHEN ol.current_status = 16 THEN ol.created_at END)
        AS first_hold_at_raw,
      MAX(CASE WHEN ol.current_status = 16 THEN ol.created_at END)
        AS last_hold_at_raw
    FROM public.order_logs ol
    WHERE ol.order_id = b.order_id
  ) la ON TRUE

  /* 1st Attempt timestamp (status 14) */
  LEFT JOIN LATERAL (
    SELECT
      MAX(CASE WHEN rn = 1 THEN created_at END) AS attempt_1_at_raw
    FROM (
      SELECT
        ol.created_at,
        ROW_NUMBER() OVER (ORDER BY ol.created_at, ol.id) AS rn
      FROM public.order_logs ol
      WHERE ol.order_id = b.order_id
        AND ol.current_status = 14
    ) x
  ) atts ON TRUE

  /* Last Hold Finished at: first 14 after last 16 */
  LEFT JOIN LATERAL (
    SELECT
      la.last_hold_at_raw AS last_hold_created_at_raw,
      (
        SELECT ol2.created_at
        FROM public.order_logs ol2
        WHERE ol2.order_id = b.order_id
          AND ol2.current_status = 14
          AND la.last_hold_at_raw IS NOT NULL
          AND ol2.created_at >= la.last_hold_at_raw
        ORDER BY ol2.created_at, ol2.id
        LIMIT 1
      ) AS last_hold_finished_at_raw
  ) hold_chain ON TRUE
),

/*----------------------------------------------------------
  4) Aggregation per LMH / zone / division / order_date
----------------------------------------------------------*/
aggregated_hub AS (
  SELECT
    f.order_date,
    f.delivery_hub_id,
    f.delivery_hub_name,
    f.delivery_zone_type,
    f.delivery_division_name,

    /* High-level LMH stock metrics */
    COUNT(*) AS total_orders_status_set,
    COUNT(*) AS total_parcels_obtained,

    COUNT(*) FILTER (
      WHERE f.transfer_status_id IN (15,17,18,19,20,21,22)
    ) AS total_processed,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 0
    ) AS orders_with_valid_lmh_term,

    AVG(
      CASE
        WHEN f.lmh_to_terminal_hours > 0 THEN f.lmh_to_terminal_hours
      END
    ) AS avg_lmh_processing_hours,

    SUM(COALESCE(f.attempt_count, 0)) AS attempt_count,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 0
    ) AS orders_with_valid_first_attempt,

    AVG(
      CASE
        WHEN f.first_attempt_aging_hours > 0 THEN f.first_attempt_aging_hours
      END
    ) AS avg_first_attempt_aging_hours,

    SUM(COALESCE(f.hold_count_non_system, 0)) AS hold_count,

    COUNT(*) FILTER (
      WHERE f.hold_aging_hours > 0
    ) AS orders_with_valid_hold,

    AVG(
      CASE
        WHEN f.hold_aging_hours > 0 THEN f.hold_aging_hours
      END
    ) AS avg_hold_aging_hours,

    /* LMH Aging buckets (LMH → Terminal), ignore <=0 */
    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 0 AND f.lmh_to_terminal_hours <= 6
    ) AS lmh_cnt_0_6,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 6 AND f.lmh_to_terminal_hours <= 12
    ) AS lmh_cnt_6_12,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 12 AND f.lmh_to_terminal_hours <= 18
    ) AS lmh_cnt_12_18,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 18 AND f.lmh_to_terminal_hours <= 24
    ) AS lmh_cnt_18_24,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 24 AND f.lmh_to_terminal_hours <= 36
    ) AS lmh_cnt_24_36,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 36 AND f.lmh_to_terminal_hours <= 48
    ) AS lmh_cnt_36_48,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 48 AND f.lmh_to_terminal_hours <= 72
    ) AS lmh_cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 72 AND f.lmh_to_terminal_hours <= 96
    ) AS lmh_cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 96 AND f.lmh_to_terminal_hours <= 120
    ) AS lmh_cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 120 AND f.lmh_to_terminal_hours <= 144
    ) AS lmh_cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 144 AND f.lmh_to_terminal_hours <= 168
    ) AS lmh_cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 168 AND f.lmh_to_terminal_hours <= 192
    ) AS lmh_cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 192 AND f.lmh_to_terminal_hours <= 216
    ) AS lmh_cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 216 AND f.lmh_to_terminal_hours <= 240
    ) AS lmh_cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 240 AND f.lmh_to_terminal_hours <= 264
    ) AS lmh_cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 264 AND f.lmh_to_terminal_hours <= 288
    ) AS lmh_cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 288 AND f.lmh_to_terminal_hours <= 312
    ) AS lmh_cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 312 AND f.lmh_to_terminal_hours <= 336
    ) AS lmh_cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 336 AND f.lmh_to_terminal_hours <= 360
    ) AS lmh_cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 360 AND f.lmh_to_terminal_hours <= 384
    ) AS lmh_cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 384 AND f.lmh_to_terminal_hours <= 408
    ) AS lmh_cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 408 AND f.lmh_to_terminal_hours <= 432
    ) AS lmh_cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 432 AND f.lmh_to_terminal_hours <= 456
    ) AS lmh_cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 456 AND f.lmh_to_terminal_hours <= 480
    ) AS lmh_cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.lmh_to_terminal_hours > 480
    ) AS lmh_cnt_480_plus,

    /* 1st Attempt Aging buckets (LMH → 1st attempt), ignore <=0 */
    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 0 AND f.first_attempt_aging_hours <= 3
    ) AS att_cnt_0_3,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 3 AND f.first_attempt_aging_hours <= 6
    ) AS att_cnt_3_6,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 6 AND f.first_attempt_aging_hours <= 12
    ) AS att_cnt_6_12,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 12 AND f.first_attempt_aging_hours <= 18
    ) AS att_cnt_12_18,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 18 AND f.first_attempt_aging_hours <= 24
    ) AS att_cnt_18_24,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 24 AND f.first_attempt_aging_hours <= 36
    ) AS att_cnt_24_36,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 36 AND f.first_attempt_aging_hours <= 48
    ) AS att_cnt_36_48,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 48 AND f.first_attempt_aging_hours <= 72
    ) AS att_cnt_48_72,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 72 AND f.first_attempt_aging_hours <= 96
    ) AS att_cnt_72_96,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 96 AND f.first_attempt_aging_hours <= 120
    ) AS att_cnt_96_120,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 120 AND f.first_attempt_aging_hours <= 144
    ) AS att_cnt_120_144,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 144 AND f.first_attempt_aging_hours <= 168
    ) AS att_cnt_144_168,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 168 AND f.first_attempt_aging_hours <= 192
    ) AS att_cnt_168_192,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 192 AND f.first_attempt_aging_hours <= 216
    ) AS att_cnt_192_216,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 216 AND f.first_attempt_aging_hours <= 240
    ) AS att_cnt_216_240,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 240 AND f.first_attempt_aging_hours <= 264
    ) AS att_cnt_240_264,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 264 AND f.first_attempt_aging_hours <= 288
    ) AS att_cnt_264_288,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 288 AND f.first_attempt_aging_hours <= 312
    ) AS att_cnt_288_312,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 312 AND f.first_attempt_aging_hours <= 336
    ) AS att_cnt_312_336,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 336 AND f.first_attempt_aging_hours <= 360
    ) AS att_cnt_336_360,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 360 AND f.first_attempt_aging_hours <= 384
    ) AS att_cnt_360_384,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 384 AND f.first_attempt_aging_hours <= 408
    ) AS att_cnt_384_408,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 408 AND f.first_attempt_aging_hours <= 432
    ) AS att_cnt_408_432,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 432 AND f.first_attempt_aging_hours <= 456
    ) AS att_cnt_432_456,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 456 AND f.first_attempt_aging_hours <= 480
    ) AS att_cnt_456_480,

    COUNT(*) FILTER (
      WHERE f.first_attempt_aging_hours > 480
    ) AS att_cnt_480_plus

  FROM flow f
  GROUP BY
    f.order_date,
    f.delivery_hub_id,
    f.delivery_hub_name,
    f.delivery_zone_type,
    f.delivery_division_name
),

/*----------------------------------------------------------
  5) Zone-level totals (OSD includes OSD + 3PL)
----------------------------------------------------------*/
zone_agg_raw AS (
  SELECT
    ah.order_date,
    CASE
      WHEN ah.delivery_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE ah.delivery_zone_type
    END AS delivery_zone_type,
    ah.total_orders_status_set,
    ah.total_parcels_obtained,
    ah.total_processed,
    ah.orders_with_valid_lmh_term,
    ah.avg_lmh_processing_hours,
    ah.attempt_count,
    ah.orders_with_valid_first_attempt,
    ah.avg_first_attempt_aging_hours,
    ah.hold_count,
    ah.orders_with_valid_hold,
    ah.avg_hold_aging_hours,
    ah.lmh_cnt_0_6,
    ah.lmh_cnt_6_12,
    ah.lmh_cnt_12_18,
    ah.lmh_cnt_18_24,
    ah.lmh_cnt_24_36,
    ah.lmh_cnt_36_48,
    ah.lmh_cnt_48_72,
    ah.lmh_cnt_72_96,
    ah.lmh_cnt_96_120,
    ah.lmh_cnt_120_144,
    ah.lmh_cnt_144_168,
    ah.lmh_cnt_168_192,
    ah.lmh_cnt_192_216,
    ah.lmh_cnt_216_240,
    ah.lmh_cnt_240_264,
    ah.lmh_cnt_264_288,
    ah.lmh_cnt_288_312,
    ah.lmh_cnt_312_336,
    ah.lmh_cnt_336_360,
    ah.lmh_cnt_360_384,
    ah.lmh_cnt_384_408,
    ah.lmh_cnt_408_432,
    ah.lmh_cnt_432_456,
    ah.lmh_cnt_456_480,
    ah.lmh_cnt_480_plus,
    ah.att_cnt_0_3,
    ah.att_cnt_3_6,
    ah.att_cnt_6_12,
    ah.att_cnt_12_18,
    ah.att_cnt_18_24,
    ah.att_cnt_24_36,
    ah.att_cnt_36_48,
    ah.att_cnt_48_72,
    ah.att_cnt_72_96,
    ah.att_cnt_96_120,
    ah.att_cnt_120_144,
    ah.att_cnt_144_168,
    ah.att_cnt_168_192,
    ah.att_cnt_192_216,
    ah.att_cnt_216_240,
    ah.att_cnt_240_264,
    ah.att_cnt_264_288,
    ah.att_cnt_288_312,
    ah.att_cnt_312_336,
    ah.att_cnt_336_360,
    ah.att_cnt_360_384,
    ah.att_cnt_384_408,
    ah.att_cnt_408_432,
    ah.att_cnt_432_456,
    ah.att_cnt_456_480,
    ah.att_cnt_480_plus
  FROM aggregated_hub ah
),

zone_agg AS (
  SELECT
    zar.order_date,
    NULL::integer AS delivery_hub_id,
    CASE
      WHEN zar.delivery_zone_type = 'ISD' THEN 'ISD Total'
      WHEN zar.delivery_zone_type = 'SUB' THEN 'SUB Total'
      WHEN zar.delivery_zone_type = 'OSD' THEN 'OSD Total'
      ELSE zar.delivery_zone_type || ' Total'
    END AS delivery_hub_name,
    zar.delivery_zone_type,
    NULL::text AS delivery_division_name,

    SUM(zar.total_orders_status_set)       AS total_orders_status_set,
    SUM(zar.total_parcels_obtained)        AS total_parcels_obtained,
    SUM(zar.total_processed)               AS total_processed,
    SUM(zar.orders_with_valid_lmh_term)    AS orders_with_valid_lmh_term,

    CASE
      WHEN SUM(zar.orders_with_valid_lmh_term) > 0
      THEN SUM(COALESCE(zar.avg_lmh_processing_hours,0) * zar.orders_with_valid_lmh_term)
           / SUM(zar.orders_with_valid_lmh_term)
    END AS avg_lmh_processing_hours,

    SUM(zar.attempt_count)                 AS attempt_count,
    SUM(zar.orders_with_valid_first_attempt) AS orders_with_valid_first_attempt,

    CASE
      WHEN SUM(zar.orders_with_valid_first_attempt) > 0
      THEN SUM(COALESCE(zar.avg_first_attempt_aging_hours,0) * zar.orders_with_valid_first_attempt)
           / SUM(zar.orders_with_valid_first_attempt)
    END AS avg_first_attempt_aging_hours,

    SUM(zar.hold_count)                    AS hold_count,
    SUM(zar.orders_with_valid_hold)        AS orders_with_valid_hold,

    CASE
      WHEN SUM(zar.orders_with_valid_hold) > 0
      THEN SUM(COALESCE(zar.avg_hold_aging_hours,0) * zar.orders_with_valid_hold)
           / SUM(zar.orders_with_valid_hold)
    END AS avg_hold_aging_hours,

    SUM(zar.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(zar.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(zar.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(zar.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(zar.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(zar.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(zar.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(zar.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(zar.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(zar.lmh_cnt_120_144) AS lmh_cnt_120_144,
    SUM(zar.lmh_cnt_144_168) AS lmh_cnt_144_168,
    SUM(zar.lmh_cnt_168_192) AS lmh_cnt_168_192,
    SUM(zar.lmh_cnt_192_216) AS lmh_cnt_192_216,
    SUM(zar.lmh_cnt_216_240) AS lmh_cnt_216_240,
    SUM(zar.lmh_cnt_240_264) AS lmh_cnt_240_264,
    SUM(zar.lmh_cnt_264_288) AS lmh_cnt_264_288,
    SUM(zar.lmh_cnt_288_312) AS lmh_cnt_288_312,
    SUM(zar.lmh_cnt_312_336) AS lmh_cnt_312_336,
    SUM(zar.lmh_cnt_336_360) AS lmh_cnt_336_360,
    SUM(zar.lmh_cnt_360_384) AS lmh_cnt_360_384,
    SUM(zar.lmh_cnt_384_408) AS lmh_cnt_384_408,
    SUM(zar.lmh_cnt_408_432) AS lmh_cnt_408_432,
    SUM(zar.lmh_cnt_432_456) AS lmh_cnt_432_456,
    SUM(zar.lmh_cnt_456_480) AS lmh_cnt_456_480,
    SUM(zar.lmh_cnt_480_plus) AS lmh_cnt_480_plus,

    SUM(zar.att_cnt_0_3)    AS att_cnt_0_3,
    SUM(zar.att_cnt_3_6)    AS att_cnt_3_6,
    SUM(zar.att_cnt_6_12)   AS att_cnt_6_12,
    SUM(zar.att_cnt_12_18)  AS att_cnt_12_18,
    SUM(zar.att_cnt_18_24)  AS att_cnt_18_24,
    SUM(zar.att_cnt_24_36)  AS att_cnt_24_36,
    SUM(zar.att_cnt_36_48)  AS att_cnt_36_48,
    SUM(zar.att_cnt_48_72)  AS att_cnt_48_72,
    SUM(zar.att_cnt_72_96)  AS att_cnt_72_96,
    SUM(zar.att_cnt_96_120) AS att_cnt_96_120,
    SUM(zar.att_cnt_120_144) AS att_cnt_120_144,
    SUM(zar.att_cnt_144_168) AS att_cnt_144_168,
    SUM(zar.att_cnt_168_192) AS att_cnt_168_192,
    SUM(zar.att_cnt_192_216) AS att_cnt_192_216,
    SUM(zar.att_cnt_216_240) AS att_cnt_216_240,
    SUM(zar.att_cnt_240_264) AS att_cnt_240_264,
    SUM(zar.att_cnt_264_288) AS att_cnt_264_288,
    SUM(zar.att_cnt_288_312) AS att_cnt_288_312,
    SUM(zar.att_cnt_312_336) AS att_cnt_312_336,
    SUM(zar.att_cnt_336_360) AS att_cnt_336_360,
    SUM(zar.att_cnt_360_384) AS att_cnt_360_384,
    SUM(zar.att_cnt_384_408) AS att_cnt_384_408,
    SUM(zar.att_cnt_408_432) AS att_cnt_408_432,
    SUM(zar.att_cnt_432_456) AS att_cnt_432_456,
    SUM(zar.att_cnt_456_480) AS att_cnt_456_480,
    SUM(zar.att_cnt_480_plus) AS att_cnt_480_plus

  FROM zone_agg_raw zar
  GROUP BY
    zar.order_date,
    zar.delivery_zone_type
),

/*----------------------------------------------------------
  6) Division-level totals
----------------------------------------------------------*/
division_agg_raw AS (
  SELECT
    ah.order_date,
    ah.delivery_zone_type,
    ah.delivery_division_name,
    ah.total_orders_status_set,
    ah.total_parcels_obtained,
    ah.total_processed,
    ah.orders_with_valid_lmh_term,
    ah.avg_lmh_processing_hours,
    ah.attempt_count,
    ah.orders_with_valid_first_attempt,
    ah.avg_first_attempt_aging_hours,
    ah.hold_count,
    ah.orders_with_valid_hold,
    ah.avg_hold_aging_hours,
    ah.lmh_cnt_0_6,
    ah.lmh_cnt_6_12,
    ah.lmh_cnt_12_18,
    ah.lmh_cnt_18_24,
    ah.lmh_cnt_24_36,
    ah.lmh_cnt_36_48,
    ah.lmh_cnt_48_72,
    ah.lmh_cnt_72_96,
    ah.lmh_cnt_96_120,
    ah.lmh_cnt_120_144,
    ah.lmh_cnt_144_168,
    ah.lmh_cnt_168_192,
    ah.lmh_cnt_192_216,
    ah.lmh_cnt_216_240,
    ah.lmh_cnt_240_264,
    ah.lmh_cnt_264_288,
    ah.lmh_cnt_288_312,
    ah.lmh_cnt_312_336,
    ah.lmh_cnt_336_360,
    ah.lmh_cnt_360_384,
    ah.lmh_cnt_384_408,
    ah.lmh_cnt_408_432,
    ah.lmh_cnt_432_456,
    ah.lmh_cnt_456_480,
    ah.lmh_cnt_480_plus,
    ah.att_cnt_0_3,
    ah.att_cnt_3_6,
    ah.att_cnt_6_12,
    ah.att_cnt_12_18,
    ah.att_cnt_18_24,
    ah.att_cnt_24_36,
    ah.att_cnt_36_48,
    ah.att_cnt_48_72,
    ah.att_cnt_72_96,
    ah.att_cnt_96_120,
    ah.att_cnt_120_144,
    ah.att_cnt_144_168,
    ah.att_cnt_168_192,
    ah.att_cnt_192_216,
    ah.att_cnt_216_240,
    ah.att_cnt_240_264,
    ah.att_cnt_264_288,
    ah.att_cnt_288_312,
    ah.att_cnt_312_336,
    ah.att_cnt_336_360,
    ah.att_cnt_360_384,
    ah.att_cnt_384_408,
    ah.att_cnt_408_432,
    ah.att_cnt_432_456,
    ah.att_cnt_456_480,
    ah.att_cnt_480_plus
  FROM aggregated_hub ah
  WHERE ah.delivery_division_name IS NOT NULL
),

division_agg AS (
  SELECT
    dr.order_date,
    NULL::integer AS delivery_hub_id,
    dr.delivery_division_name || ' Total' AS delivery_hub_name,
    dr.delivery_zone_type,
    dr.delivery_division_name,

    SUM(dr.total_orders_status_set)        AS total_orders_status_set,
    SUM(dr.total_parcels_obtained)         AS total_parcels_obtained,
    SUM(dr.total_processed)                AS total_processed,
    SUM(dr.orders_with_valid_lmh_term)     AS orders_with_valid_lmh_term,

    CASE
      WHEN SUM(dr.orders_with_valid_lmh_term) > 0
      THEN SUM(COALESCE(dr.avg_lmh_processing_hours,0) * dr.orders_with_valid_lmh_term)
           / SUM(dr.orders_with_valid_lmh_term)
    END AS avg_lmh_processing_hours,

    SUM(dr.attempt_count)                  AS attempt_count,
    SUM(dr.orders_with_valid_first_attempt) AS orders_with_valid_first_attempt,

    CASE
      WHEN SUM(dr.orders_with_valid_first_attempt) > 0
      THEN SUM(COALESCE(dr.avg_first_attempt_aging_hours,0) * dr.orders_with_valid_first_attempt)
           / SUM(dr.orders_with_valid_first_attempt)
    END AS avg_first_attempt_aging_hours,

    SUM(dr.hold_count)                     AS hold_count,
    SUM(dr.orders_with_valid_hold)         AS orders_with_valid_hold,

    CASE
      WHEN SUM(dr.orders_with_valid_hold) > 0
      THEN SUM(COALESCE(dr.avg_hold_aging_hours,0) * dr.orders_with_valid_hold)
           / SUM(dr.orders_with_valid_hold)
    END AS avg_hold_aging_hours,

    SUM(dr.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(dr.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(dr.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(dr.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(dr.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(dr.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(dr.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(dr.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(dr.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(dr.lmh_cnt_120_144) AS lmh_cnt_120_144,
    SUM(dr.lmh_cnt_144_168) AS lmh_cnt_144_168,
    SUM(dr.lmh_cnt_168_192) AS lmh_cnt_168_192,
    SUM(dr.lmh_cnt_192_216) AS lmh_cnt_192_216,
    SUM(dr.lmh_cnt_216_240) AS lmh_cnt_216_240,
    SUM(dr.lmh_cnt_240_264) AS lmh_cnt_240_264,
    SUM(dr.lmh_cnt_264_288) AS lmh_cnt_264_288,
    SUM(dr.lmh_cnt_288_312) AS lmh_cnt_288_312,
    SUM(dr.lmh_cnt_312_336) AS lmh_cnt_312_336,
    SUM(dr.lmh_cnt_336_360) AS lmh_cnt_336_360,
    SUM(dr.lmh_cnt_360_384) AS lmh_cnt_360_384,
    SUM(dr.lmh_cnt_384_408) AS lmh_cnt_384_408,
    SUM(dr.lmh_cnt_408_432) AS lmh_cnt_408_432,
    SUM(dr.lmh_cnt_432_456) AS lmh_cnt_432_456,
    SUM(dr.lmh_cnt_456_480) AS lmh_cnt_456_480,
    SUM(dr.lmh_cnt_480_plus) AS lmh_cnt_480_plus,

    SUM(dr.att_cnt_0_3)    AS att_cnt_0_3,
    SUM(dr.att_cnt_3_6)    AS att_cnt_3_6,
    SUM(dr.att_cnt_6_12)   AS att_cnt_6_12,
    SUM(dr.att_cnt_12_18)  AS att_cnt_12_18,
    SUM(dr.att_cnt_18_24)  AS att_cnt_18_24,
    SUM(dr.att_cnt_24_36)  AS att_cnt_24_36,
    SUM(dr.att_cnt_36_48)  AS att_cnt_36_48,
    SUM(dr.att_cnt_48_72)  AS att_cnt_48_72,
    SUM(dr.att_cnt_72_96)  AS att_cnt_72_96,
    SUM(dr.att_cnt_96_120) AS att_cnt_96_120,
    SUM(dr.att_cnt_120_144) AS att_cnt_120_144,
    SUM(dr.att_cnt_144_168) AS att_cnt_144_168,
    SUM(dr.att_cnt_168_192) AS att_cnt_168_192,
    SUM(dr.att_cnt_192_216) AS att_cnt_192_216,
    SUM(dr.att_cnt_216_240) AS att_cnt_216_240,
    SUM(dr.att_cnt_240_264) AS att_cnt_240_264,
    SUM(dr.att_cnt_264_288) AS att_cnt_264_288,
    SUM(dr.att_cnt_288_312) AS att_cnt_288_312,
    SUM(dr.att_cnt_312_336) AS att_cnt_312_336,
    SUM(dr.att_cnt_336_360) AS att_cnt_336_360,
    SUM(dr.att_cnt_360_384) AS att_cnt_360_384,
    SUM(dr.att_cnt_384_408) AS att_cnt_384_408,
    SUM(dr.att_cnt_408_432) AS att_cnt_408_432,
    SUM(dr.att_cnt_432_456) AS att_cnt_432_456,
    SUM(dr.att_cnt_456_480) AS att_cnt_456_480,
    SUM(dr.att_cnt_480_plus) AS att_cnt_480_plus

  FROM division_agg_raw dr
  GROUP BY
    dr.order_date,
    dr.delivery_zone_type,
    dr.delivery_division_name
),

/*----------------------------------------------------------
  7) Global totals (all zones + divisions)
----------------------------------------------------------*/
global_agg_raw AS (
  SELECT
    ah.order_date,
    ah.total_orders_status_set,
    ah.total_parcels_obtained,
    ah.total_processed,
    ah.orders_with_valid_lmh_term,
    ah.avg_lmh_processing_hours,
    ah.attempt_count,
    ah.orders_with_valid_first_attempt,
    ah.avg_first_attempt_aging_hours,
    ah.hold_count,
    ah.orders_with_valid_hold,
    ah.avg_hold_aging_hours,
    ah.lmh_cnt_0_6,
    ah.lmh_cnt_6_12,
    ah.lmh_cnt_12_18,
    ah.lmh_cnt_18_24,
    ah.lmh_cnt_24_36,
    ah.lmh_cnt_36_48,
    ah.lmh_cnt_48_72,
    ah.lmh_cnt_72_96,
    ah.lmh_cnt_96_120,
    ah.lmh_cnt_120_144,
    ah.lmh_cnt_144_168,
    ah.lmh_cnt_168_192,
    ah.lmh_cnt_192_216,
    ah.lmh_cnt_216_240,
    ah.lmh_cnt_240_264,
    ah.lmh_cnt_264_288,
    ah.lmh_cnt_288_312,
    ah.lmh_cnt_312_336,
    ah.lmh_cnt_336_360,
    ah.lmh_cnt_360_384,
    ah.lmh_cnt_384_408,
    ah.lmh_cnt_408_432,
    ah.lmh_cnt_432_456,
    ah.lmh_cnt_456_480,
    ah.lmh_cnt_480_plus,
    ah.att_cnt_0_3,
    ah.att_cnt_3_6,
    ah.att_cnt_6_12,
    ah.att_cnt_12_18,
    ah.att_cnt_18_24,
    ah.att_cnt_24_36,
    ah.att_cnt_36_48,
    ah.att_cnt_48_72,
    ah.att_cnt_72_96,
    ah.att_cnt_96_120,
    ah.att_cnt_120_144,
    ah.att_cnt_144_168,
    ah.att_cnt_168_192,
    ah.att_cnt_192_216,
    ah.att_cnt_216_240,
    ah.att_cnt_240_264,
    ah.att_cnt_264_288,
    ah.att_cnt_288_312,
    ah.att_cnt_312_336,
    ah.att_cnt_336_360,
    ah.att_cnt_360_384,
    ah.att_cnt_384_408,
    ah.att_cnt_408_432,
    ah.att_cnt_432_456,
    ah.att_cnt_456_480,
    ah.att_cnt_480_plus
  FROM aggregated_hub ah
),

global_agg AS (
  SELECT
    ga.order_date,
    NULL::integer AS delivery_hub_id,
    'Global Total' AS delivery_hub_name,
    'Global' AS delivery_zone_type,
    NULL::text AS delivery_division_name,

    SUM(ga.total_orders_status_set)       AS total_orders_status_set,
    SUM(ga.total_parcels_obtained)        AS total_parcels_obtained,
    SUM(ga.total_processed)               AS total_processed,
    SUM(ga.orders_with_valid_lmh_term)    AS orders_with_valid_lmh_term,

    CASE
      WHEN SUM(ga.orders_with_valid_lmh_term) > 0
      THEN SUM(COALESCE(ga.avg_lmh_processing_hours,0) * ga.orders_with_valid_lmh_term)
           / SUM(ga.orders_with_valid_lmh_term)
    END AS avg_lmh_processing_hours,

    SUM(ga.attempt_count)                 AS attempt_count,
    SUM(ga.orders_with_valid_first_attempt) AS orders_with_valid_first_attempt,

    CASE
      WHEN SUM(ga.orders_with_valid_first_attempt) > 0
      THEN SUM(COALESCE(ga.avg_first_attempt_aging_hours,0) * ga.orders_with_valid_first_attempt)
           / SUM(ga.orders_with_valid_first_attempt)
    END AS avg_first_attempt_aging_hours,

    SUM(ga.hold_count)                    AS hold_count,
    SUM(ga.orders_with_valid_hold)        AS orders_with_valid_hold,

    CASE
      WHEN SUM(ga.orders_with_valid_hold) > 0
      THEN SUM(COALESCE(ga.avg_hold_aging_hours,0) * ga.orders_with_valid_hold)
           / SUM(ga.orders_with_valid_hold)
    END AS avg_hold_aging_hours,

    SUM(ga.lmh_cnt_0_6)    AS lmh_cnt_0_6,
    SUM(ga.lmh_cnt_6_12)   AS lmh_cnt_6_12,
    SUM(ga.lmh_cnt_12_18)  AS lmh_cnt_12_18,
    SUM(ga.lmh_cnt_18_24)  AS lmh_cnt_18_24,
    SUM(ga.lmh_cnt_24_36)  AS lmh_cnt_24_36,
    SUM(ga.lmh_cnt_36_48)  AS lmh_cnt_36_48,
    SUM(ga.lmh_cnt_48_72)  AS lmh_cnt_48_72,
    SUM(ga.lmh_cnt_72_96)  AS lmh_cnt_72_96,
    SUM(ga.lmh_cnt_96_120) AS lmh_cnt_96_120,
    SUM(ga.lmh_cnt_120_144) AS lmh_cnt_120_144,
    SUM(ga.lmh_cnt_144_168) AS lmh_cnt_144_168,
    SUM(ga.lmh_cnt_168_192) AS lmh_cnt_168_192,
    SUM(ga.lmh_cnt_192_216) AS lmh_cnt_192_216,
    SUM(ga.lmh_cnt_216_240) AS lmh_cnt_216_240,
    SUM(ga.lmh_cnt_240_264) AS lmh_cnt_240_264,
    SUM(ga.lmh_cnt_264_288) AS lmh_cnt_264_288,
    SUM(ga.lmh_cnt_288_312) AS lmh_cnt_288_312,
    SUM(ga.lmh_cnt_312_336) AS lmh_cnt_312_336,
    SUM(ga.lmh_cnt_336_360) AS lmh_cnt_336_360,
    SUM(ga.lmh_cnt_360_384) AS lmh_cnt_360_384,
    SUM(ga.lmh_cnt_384_408) AS lmh_cnt_384_408,
    SUM(ga.lmh_cnt_408_432) AS lmh_cnt_408_432,
    SUM(ga.lmh_cnt_432_456) AS lmh_cnt_432_456,
    SUM(ga.lmh_cnt_456_480) AS lmh_cnt_456_480,
    SUM(ga.lmh_cnt_480_plus) AS lmh_cnt_480_plus,

    SUM(ga.att_cnt_0_3)    AS att_cnt_0_3,
    SUM(ga.att_cnt_3_6)    AS att_cnt_3_6,
    SUM(ga.att_cnt_6_12)   AS att_cnt_6_12,
    SUM(ga.att_cnt_12_18)  AS att_cnt_12_18,
    SUM(ga.att_cnt_18_24)  AS att_cnt_18_24,
    SUM(ga.att_cnt_24_36)  AS att_cnt_24_36,
    SUM(ga.att_cnt_36_48)  AS att_cnt_36_48,
    SUM(ga.att_cnt_48_72)  AS att_cnt_48_72,
    SUM(ga.att_cnt_72_96)  AS att_cnt_72_96,
    SUM(ga.att_cnt_96_120) AS att_cnt_96_120,
    SUM(ga.att_cnt_120_144) AS att_cnt_120_144,
    SUM(ga.att_cnt_144_168) AS att_cnt_144_168,
    SUM(ga.att_cnt_168_192) AS att_cnt_168_192,
    SUM(ga.att_cnt_192_216) AS att_cnt_192_216,
    SUM(ga.att_cnt_216_240) AS att_cnt_216_240,
    SUM(ga.att_cnt_240_264) AS att_cnt_240_264,
    SUM(ga.att_cnt_264_288) AS att_cnt_264_288,
    SUM(ga.att_cnt_288_312) AS att_cnt_288_312,
    SUM(ga.att_cnt_312_336) AS att_cnt_312_336,
    SUM(ga.att_cnt_336_360) AS att_cnt_336_360,
    SUM(ga.att_cnt_360_384) AS att_cnt_360_384,
    SUM(ga.att_cnt_384_408) AS att_cnt_384_408,
    SUM(ga.att_cnt_408_432) AS att_cnt_408_432,
    SUM(ga.att_cnt_432_456) AS att_cnt_432_456,
    SUM(ga.att_cnt_456_480) AS att_cnt_456_480,
    SUM(ga.att_cnt_480_plus) AS att_cnt_480_plus

  FROM global_agg_raw ga
  GROUP BY
    ga.order_date
),

/*----------------------------------------------------------
  8) Add rolling 7-day averages for hubs, zones, divisions, global
----------------------------------------------------------*/
hub_metrics AS (
  SELECT
    ah.*,
    AVG(ah.avg_lmh_processing_hours) OVER (
      PARTITION BY ah.delivery_hub_id
      ORDER BY ah.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_lmh_processing_hours,
    AVG(ah.avg_first_attempt_aging_hours) OVER (
      PARTITION BY ah.delivery_hub_id
      ORDER BY ah.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_first_attempt_aging_hours
  FROM aggregated_hub ah
),

zone_metrics AS (
  SELECT
    za.*,
    AVG(za.avg_lmh_processing_hours) OVER (
      PARTITION BY za.delivery_zone_type
      ORDER BY za.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_lmh_processing_hours,
    AVG(za.avg_first_attempt_aging_hours) OVER (
      PARTITION BY za.delivery_zone_type
      ORDER BY za.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_first_attempt_aging_hours
  FROM zone_agg za
),

division_metrics AS (
  SELECT
    da.*,
    AVG(da.avg_lmh_processing_hours) OVER (
      PARTITION BY da.delivery_division_name
      ORDER BY da.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_lmh_processing_hours,
    AVG(da.avg_first_attempt_aging_hours) OVER (
      PARTITION BY da.delivery_division_name
      ORDER BY da.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_first_attempt_aging_hours
  FROM division_agg da
),

global_metrics AS (
  SELECT
    ga.*,
    AVG(ga.avg_lmh_processing_hours) OVER (
      ORDER BY ga.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_lmh_processing_hours,
    AVG(ga.avg_first_attempt_aging_hours) OVER (
      ORDER BY ga.order_date
      ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    ) AS last_7_first_attempt_aging_hours
  FROM global_agg ga
),

/*----------------------------------------------------------
  9) Combine hub rows + zone totals + division totals + global total
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
  10) Final select – adds backlog, labels, percentages (0–1)
----------------------------------------------------------*/
SELECT
  c.order_date          AS "Order Date",
  c.delivery_hub_id     AS "Last Mile Hub ID",
  c.delivery_hub_name   AS "Last Mile Hub Name",
  c.delivery_zone_type  AS "Last Mile Zone",
  c.delivery_division_name AS "Last Mile Division",

  c.total_orders_status_set  AS "Total Orders",
  c.total_parcels_obtained   AS "Total Parcels Obtained",
  c.total_processed          AS "Total Processed",
  (c.total_parcels_obtained - c.total_processed)
                             AS "Failed to Process",

  c.orders_with_valid_lmh_term
                             AS "Orders with LMH to terminal",

  ROUND(c.avg_lmh_processing_hours, 2)
    AS "Avg LMH Processing Time (hrs)",

  ROUND(c.last_7_lmh_processing_hours, 2)
    AS "Last 7 days avg LMH processing time (hrs)",

  c.attempt_count AS "Attempt Count",

  c.orders_with_valid_first_attempt
    AS "Orders with 1st Attempt segment",

  ROUND(c.avg_first_attempt_aging_hours, 2)
    AS "Avg 1st Attempt Aging (hrs)",

  ROUND(c.last_7_first_attempt_aging_hours, 2)
    AS "Last 7 days avg 1st Attempt Aging (hrs)",

  c.hold_count AS "Hold Count",
  c.orders_with_valid_hold AS "Orders with Hold segment",
  ROUND(c.avg_hold_aging_hours, 2)
    AS "Avg Hold Aging (hrs)",

  /* ===== LMH Aging Brackets (LMH → Terminal) – main buckets (counts) ===== */
  c.lmh_cnt_0_6   AS "LMH 6 hrs",
  c.lmh_cnt_6_12  AS "LMH 12 hrs",
  c.lmh_cnt_12_18 AS "LMH 18 hrs",
  c.lmh_cnt_18_24 AS "LMH 24 hrs",
  c.lmh_cnt_24_36 AS "LMH 36 hrs",
  c.lmh_cnt_36_48 AS "LMH 48 hrs",
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
  ) AS "LMH 48 hrs++",

  /* ===== LMH Aging Brackets – FRACTION of orders_with_valid_lmh_term ===== */
  ROUND(
    c.lmh_cnt_0_6::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 6 hrs",

  ROUND(
    c.lmh_cnt_6_12::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 12 hrs",

  ROUND(
    c.lmh_cnt_12_18::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 18 hrs",

  ROUND(
    c.lmh_cnt_18_24::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 24 hrs",

  ROUND(
    c.lmh_cnt_24_36::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 36 hrs",

  ROUND(
    c.lmh_cnt_36_48::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 48 hrs",

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
    )::numeric /
    NULLIF(c.orders_with_valid_lmh_term, 0),
    2
  ) AS "% LMH 48 hrs++",

  /* ===== LMH Extended buckets (counts only, 72–480 & 480++) ===== */
  c.lmh_cnt_72_96   AS "LMH 72 hrs",
  c.lmh_cnt_96_120  AS "LMH 96 hrs",
  c.lmh_cnt_120_144 AS "LMH 120 hrs",
  c.lmh_cnt_144_168 AS "LMH 144 hrs",
  c.lmh_cnt_168_192 AS "LMH 168 hrs",
  c.lmh_cnt_192_216 AS "LMH 192 hrs",
  c.lmh_cnt_216_240 AS "LMH 216 hrs",
  c.lmh_cnt_240_264 AS "LMH 240 hrs",
  c.lmh_cnt_264_288 AS "LMH 264 hrs",
  c.lmh_cnt_288_312 AS "LMH 288 hrs",
  c.lmh_cnt_312_336 AS "LMH 312 hrs",
  c.lmh_cnt_336_360 AS "LMH 336 hrs",
  c.lmh_cnt_360_384 AS "LMH 360 hrs",
  c.lmh_cnt_384_408 AS "LMH 384 hrs",
  c.lmh_cnt_408_432 AS "LMH 408 hrs",
  c.lmh_cnt_432_456 AS "LMH 432 hrs",
  c.lmh_cnt_456_480 AS "LMH 456 hrs",
  c.lmh_cnt_480_plus AS "LMH 480 hrs++",

  /* ===== 1st Attempt Aging Brackets – main buckets (counts) ===== */
  c.att_cnt_0_3   AS "1st Attempt 3 hrs",
  c.att_cnt_3_6   AS "1st Attempt 6 hrs",
  c.att_cnt_6_12  AS "1st Attempt 12 hrs",
  c.att_cnt_12_18 AS "1st Attempt 18 hrs",
  c.att_cnt_18_24 AS "1st Attempt 24 hrs",
  c.att_cnt_24_36 AS "1st Attempt 36 hrs",
  c.att_cnt_36_48 AS "1st Attempt 48 hrs",
  (
    c.att_cnt_48_72
    + c.att_cnt_72_96
    + c.att_cnt_96_120
    + c.att_cnt_120_144
    + c.att_cnt_144_168
    + c.att_cnt_168_192
    + c.att_cnt_192_216
    + c.att_cnt_216_240
    + c.att_cnt_240_264
    + c.att_cnt_264_288
    + c.att_cnt_288_312
    + c.att_cnt_312_336
    + c.att_cnt_336_360
    + c.att_cnt_360_384
    + c.att_cnt_384_408
    + c.att_cnt_408_432
    + c.att_cnt_432_456
    + c.att_cnt_456_480
    + c.att_cnt_480_plus
  ) AS "1st Attempt 48 hrs++",

  /* ===== 1st Attempt Aging – FRACTION of orders_with_valid_first_attempt ===== */
  ROUND(
    c.att_cnt_0_3::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 3 hrs",

  ROUND(
    c.att_cnt_3_6::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 6 hrs",

  ROUND(
    c.att_cnt_6_12::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 12 hrs",

  ROUND(
    c.att_cnt_12_18::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 18 hrs",

  ROUND(
    c.att_cnt_18_24::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 24 hrs",

  ROUND(
    c.att_cnt_24_36::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 36 hrs",

  ROUND(
    c.att_cnt_36_48::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 48 hrs",

  ROUND(
    (
      c.att_cnt_48_72
      + c.att_cnt_72_96
      + c.att_cnt_96_120
      + c.att_cnt_120_144
      + c.att_cnt_144_168
      + c.att_cnt_168_192
      + c.att_cnt_192_216
      + c.att_cnt_216_240
      + c.att_cnt_240_264
      + c.att_cnt_264_288
      + c.att_cnt_288_312
      + c.att_cnt_312_336
      + c.att_cnt_336_360
      + c.att_cnt_360_384
      + c.att_cnt_384_408
      + c.att_cnt_408_432
      + c.att_cnt_432_456
      + c.att_cnt_456_480
      + c.att_cnt_480_plus
    )::numeric /
    NULLIF(c.orders_with_valid_first_attempt, 0),
    2
  ) AS "% 1st Attempt 48 hrs++",

  /* ===== 1st Attempt Extended buckets (counts only, 72–480 & 480++) ===== */
  c.att_cnt_72_96   AS "1st Attempt 72 hrs",
  c.att_cnt_96_120  AS "1st Attempt 96 hrs",
  c.att_cnt_120_144 AS "1st Attempt 120 hrs",
  c.att_cnt_144_168 AS "1st Attempt 144 hrs",
  c.att_cnt_168_192 AS "1st Attempt 168 hrs",
  c.att_cnt_192_216 AS "1st Attempt 192 hrs",
  c.att_cnt_216_240 AS "1st Attempt 216 hrs",
  c.att_cnt_240_264 AS "1st Attempt 240 hrs",
  c.att_cnt_264_288 AS "1st Attempt 264 hrs",
  c.att_cnt_288_312 AS "1st Attempt 288 hrs",
  c.att_cnt_312_336 AS "1st Attempt 312 hrs",
  c.att_cnt_336_360 AS "1st Attempt 336 hrs",
  c.att_cnt_360_384 AS "1st Attempt 360 hrs",
  c.att_cnt_384_408 AS "1st Attempt 384 hrs",
  c.att_cnt_408_432 AS "1st Attempt 408 hrs",
  c.att_cnt_432_456 AS "1st Attempt 432 hrs",
  c.att_cnt_456_480 AS "1st Attempt 456 hrs",
  c.att_cnt_480_plus AS "1st Attempt 480 hrs++"

FROM combined c
ORDER BY
  c.order_date,
  c.delivery_zone_type,
  c.delivery_division_name,
  c.delivery_hub_name;
