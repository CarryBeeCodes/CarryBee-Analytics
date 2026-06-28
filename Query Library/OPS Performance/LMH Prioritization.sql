/* ============================================================
   LMH Prioritization – Sorted→LMH vs LMH→Terminal (DoD)
   - Row = Order Date (sorted_at + 6h) + Delivery Hub + Zone + Division
           + Sorted→LMH Aging Bracket
   - Domain: only terminal-status orders at LMH:
       transfer_status_id IN (15,17,18,19,20,21,22)
   - Columns:
       * Sorted→LMH Orders (row denominator)
       * LMH→Terminal bracket counts:
           12 hrs, 24 hrs, 48 hrs, 72 hrs, 96 hrs, 120 hrs,
           144 hrs, 168 hrs, 192 hrs, 216 hrs, 240 hrs, 240 hrs++
       * LMH→Terminal bracket FRACTION of row (per sorted bracket):
           % 12 hrs, % 24 hrs, ..., % 240 hrs, % 240 hrs++
         (fractions 0–1, ready to format as % in Excel)
   - Aging definitions (both metrics use same buckets):
       (0,12] → '12 hrs'
       (12,24] → '24 hrs'
       (24,48] → '48 hrs'
       (48,72] → '72 hrs'
       (72,96] → '96 hrs'
       (96,120] → '120 hrs'
       (120,144] → '144 hrs'
       (144,168] → '168 hrs'
       (168,192] → '192 hrs'
       (192,216] → '216 hrs'
       (216,240] → '240 hrs'
       >240     → '240 hrs++'
   - Ignore any aging value <= 0 or NULL for both metrics
   - Only orders with BOTH positive Sorted→LMH and LMH→Terminal are used

   Extra rows:
     * Zone totals (OSD Total = OSD + 3PL)
     * Division totals (Barisal Total, CTG Total, Dhaka ISD Total, etc.)
     * Global Total (all LMH)

   Zone / hub mapping updates applied:
     - 162 Keraniganj-Ati Bazar → Zone: SUB, Division: Dhaka Sub
     - 163 Narayanganj-Bandar   → Zone: SUB, Division: Dhaka Sub
     - 161 Central IB           → Zone: Central Inbound
     - 153–159 (Bhanga / Barishal / Bhairab / Sirajgonj /
               Comilla / Rangpur / Sylhet Sub Sort)
                                 → Zone: Sub Sort
     - 71 Central Sort          → Zone: Central Warehouse
     - 72 Central Return        → Zone: Central Warehouse
============================================================ */

WITH
/*----------------------------------------------------------
  1) Hub → Zone + Division map (UPDATED)
----------------------------------------------------------*/
hub_zone_map AS (
  SELECT
    h.id AS hub_id,

    /* Zone type (high-level): ISD, SUB, 3PL, OSD, Central Inbound,
       Sub Sort, Central Warehouse */
    CASE
      WHEN h.id = 161 THEN 'Central Inbound'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort'
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163)
        THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type,

    /* Division name (as provided, with 162,163 → Dhaka Sub) */
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
  2) Base orders – delivery hub, zone, division, DoD (sorted_at-based)
----------------------------------------------------------*/
base AS (
  SELECT
    o.id                                     AS order_id,
    o.sorted_at,
    o.transfer_status_updated_at,
    (o.sorted_at + INTERVAL '6 hours')::date AS order_date,
    dh.id                                    AS delivery_hub_id,
    dh.name                                  AS delivery_hub_name,
    dhz.zone_type                            AS delivery_zone_type,
    dhz.division_name                        AS delivery_division_name
  FROM orders o
  LEFT JOIN hubs         dh  ON dh.id = o.delivery_hub_id
  LEFT JOIN hub_zone_map dhz ON dhz.hub_id = dh.id
  WHERE
        o.business_id <> 10
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-08-25 00:00:00'
     AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-01 00:00:00'

    /* Terminal from LMH POV */
    AND o.transfer_status_id IN (15,17,18,19,20,21,22)
),

/*----------------------------------------------------------
  3) Per-order LMH logs + raw aging values
----------------------------------------------------------*/
flow AS (
  SELECT
    b.*,
    la.lmh_logs_raw,

    /* Sorted → LMH (hrs) */
    CASE
      WHEN b.sorted_at IS NOT NULL
       AND la.lmh_logs_raw IS NOT NULL
      THEN ROUND(
             EXTRACT(EPOCH FROM (la.lmh_logs_raw - b.sorted_at)) / 3600.0,
           2)
    END AS sorted_to_lmh_hours,

    /* LMH → Terminal (hrs) */
    CASE
      WHEN la.lmh_logs_raw IS NOT NULL
       AND b.transfer_status_updated_at IS NOT NULL
      THEN ROUND(
             EXTRACT(EPOCH FROM (b.transfer_status_updated_at - la.lmh_logs_raw)) / 3600.0,
           2)
    END AS lmh_to_terminal_hours
  FROM base b

  /* Last Mile at (Logs) – earliest status 13 */
  LEFT JOIN LATERAL (
    SELECT
      MIN(CASE WHEN ol.current_status = 13 THEN ol.created_at END)
        AS lmh_logs_raw
    FROM order_logs ol
    WHERE ol.order_id = b.order_id
  ) la ON TRUE
),

/*----------------------------------------------------------
  4) Bucket both metrics into common 12/24/48/... scheme
----------------------------------------------------------*/
classified AS (
  SELECT
    f.*,

    /* Sorted → LMH aging bracket */
    CASE
      WHEN f.sorted_to_lmh_hours  > 0 AND f.sorted_to_lmh_hours <= 12 THEN '12 hrs'
      WHEN f.sorted_to_lmh_hours  > 12 AND f.sorted_to_lmh_hours <= 24 THEN '24 hrs'
      WHEN f.sorted_to_lmh_hours  > 24 AND f.sorted_to_lmh_hours <= 48 THEN '48 hrs'
      WHEN f.sorted_to_lmh_hours  > 48 AND f.sorted_to_lmh_hours <= 72 THEN '72 hrs'
      WHEN f.sorted_to_lmh_hours  > 72 AND f.sorted_to_lmh_hours <= 96 THEN '96 hrs'
      WHEN f.sorted_to_lmh_hours  > 96 AND f.sorted_to_lmh_hours <= 120 THEN '120 hrs'
      WHEN f.sorted_to_lmh_hours  > 120 AND f.sorted_to_lmh_hours <= 144 THEN '144 hrs'
      WHEN f.sorted_to_lmh_hours  > 144 AND f.sorted_to_lmh_hours <= 168 THEN '168 hrs'
      WHEN f.sorted_to_lmh_hours  > 168 AND f.sorted_to_lmh_hours <= 192 THEN '192 hrs'
      WHEN f.sorted_to_lmh_hours  > 192 AND f.sorted_to_lmh_hours <= 216 THEN '216 hrs'
      WHEN f.sorted_to_lmh_hours  > 216 AND f.sorted_to_lmh_hours <= 240 THEN '240 hrs'
      WHEN f.sorted_to_lmh_hours  > 240 THEN '240 hrs++'
    END AS sorted_lmh_bracket,

    /* LMH → Terminal aging bracket */
    CASE
      WHEN f.lmh_to_terminal_hours  > 0 AND f.lmh_to_terminal_hours <= 12 THEN '12 hrs'
      WHEN f.lmh_to_terminal_hours  > 12 AND f.lmh_to_terminal_hours <= 24 THEN '24 hrs'
      WHEN f.lmh_to_terminal_hours  > 24 AND f.lmh_to_terminal_hours <= 48 THEN '48 hrs'
      WHEN f.lmh_to_terminal_hours  > 48 AND f.lmh_to_terminal_hours <= 72 THEN '72 hrs'
      WHEN f.lmh_to_terminal_hours  > 72 AND f.lmh_to_terminal_hours <= 96 THEN '96 hrs'
      WHEN f.lmh_to_terminal_hours  > 96 AND f.lmh_to_terminal_hours <= 120 THEN '120 hrs'
      WHEN f.lmh_to_terminal_hours  > 120 AND f.lmh_to_terminal_hours <= 144 THEN '144 hrs'
      WHEN f.lmh_to_terminal_hours  > 144 AND f.lmh_to_terminal_hours <= 168 THEN '168 hrs'
      WHEN f.lmh_to_terminal_hours  > 168 AND f.lmh_to_terminal_hours <= 192 THEN '192 hrs'
      WHEN f.lmh_to_terminal_hours  > 192 AND f.lmh_to_terminal_hours <= 216 THEN '216 hrs'
      WHEN f.lmh_to_terminal_hours  > 216 AND f.lmh_to_terminal_hours <= 240 THEN '240 hrs'
      WHEN f.lmh_to_terminal_hours  > 240 THEN '240 hrs++'
    END AS lmh_terminal_bracket

  FROM flow f
),

/*----------------------------------------------------------
  5) Hub-level aggregation by DoD + hub + zone + division + Sorted→LMH bracket
     Only orders where BOTH brackets are non-null
----------------------------------------------------------*/
aggregated AS (
  SELECT
    c.order_date,
    c.delivery_hub_id,
    c.delivery_hub_name,
    c.delivery_zone_type,
    c.delivery_division_name,
    c.sorted_lmh_bracket,

    /* row denominator for this Sorted→LMH bracket */
    COUNT(*) AS sorted_lmh_orders,

    /* LMH→Terminal bracket counts for this row */
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '12 hrs')    AS cnt_lmh_12,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '24 hrs')    AS cnt_lmh_24,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '48 hrs')    AS cnt_lmh_48,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '72 hrs')    AS cnt_lmh_72,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '96 hrs')    AS cnt_lmh_96,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '120 hrs')   AS cnt_lmh_120,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '144 hrs')   AS cnt_lmh_144,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '168 hrs')   AS cnt_lmh_168,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '192 hrs')   AS cnt_lmh_192,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '216 hrs')   AS cnt_lmh_216,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '240 hrs')   AS cnt_lmh_240,
    COUNT(*) FILTER (WHERE c.lmh_terminal_bracket = '240 hrs++') AS cnt_lmh_240_plus

  FROM classified c
  WHERE
        c.sorted_lmh_bracket IS NOT NULL
    AND c.lmh_terminal_bracket IS NOT NULL
  GROUP BY
    c.order_date,
    c.delivery_hub_id,
    c.delivery_hub_name,
    c.delivery_zone_type,
    c.delivery_division_name,
    c.sorted_lmh_bracket
),

/*----------------------------------------------------------
  6) Zone-level totals (OSD + 3PL combined into OSD), per bracket
----------------------------------------------------------*/
zone_agg_raw AS (
  SELECT
    a.order_date,
    CASE
      WHEN a.delivery_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE a.delivery_zone_type
    END AS delivery_zone_type,
    a.sorted_lmh_bracket,
    SUM(a.sorted_lmh_orders)  AS sorted_lmh_orders,
    SUM(a.cnt_lmh_12)         AS cnt_lmh_12,
    SUM(a.cnt_lmh_24)         AS cnt_lmh_24,
    SUM(a.cnt_lmh_48)         AS cnt_lmh_48,
    SUM(a.cnt_lmh_72)         AS cnt_lmh_72,
    SUM(a.cnt_lmh_96)         AS cnt_lmh_96,
    SUM(a.cnt_lmh_120)        AS cnt_lmh_120,
    SUM(a.cnt_lmh_144)        AS cnt_lmh_144,
    SUM(a.cnt_lmh_168)        AS cnt_lmh_168,
    SUM(a.cnt_lmh_192)        AS cnt_lmh_192,
    SUM(a.cnt_lmh_216)        AS cnt_lmh_216,
    SUM(a.cnt_lmh_240)        AS cnt_lmh_240,
    SUM(a.cnt_lmh_240_plus)   AS cnt_lmh_240_plus
  FROM aggregated a
  GROUP BY
    a.order_date,
    CASE
      WHEN a.delivery_zone_type IN ('OSD','3PL') THEN 'OSD'
      ELSE a.delivery_zone_type
    END,
    a.sorted_lmh_bracket
),

zone_metrics AS (
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
    z.sorted_lmh_bracket,
    z.sorted_lmh_orders,
    z.cnt_lmh_12,
    z.cnt_lmh_24,
    z.cnt_lmh_48,
    z.cnt_lmh_72,
    z.cnt_lmh_96,
    z.cnt_lmh_120,
    z.cnt_lmh_144,
    z.cnt_lmh_168,
    z.cnt_lmh_192,
    z.cnt_lmh_216,
    z.cnt_lmh_240,
    z.cnt_lmh_240_plus
  FROM zone_agg_raw z
),

/*----------------------------------------------------------
  7) Division-level totals, per bracket
----------------------------------------------------------*/
division_agg_raw AS (
  SELECT
    a.order_date,
    a.delivery_zone_type,
    a.delivery_division_name,
    a.sorted_lmh_bracket,
    SUM(a.sorted_lmh_orders)  AS sorted_lmh_orders,
    SUM(a.cnt_lmh_12)         AS cnt_lmh_12,
    SUM(a.cnt_lmh_24)         AS cnt_lmh_24,
    SUM(a.cnt_lmh_48)         AS cnt_lmh_48,
    SUM(a.cnt_lmh_72)         AS cnt_lmh_72,
    SUM(a.cnt_lmh_96)         AS cnt_lmh_96,
    SUM(a.cnt_lmh_120)        AS cnt_lmh_120,
    SUM(a.cnt_lmh_144)        AS cnt_lmh_144,
    SUM(a.cnt_lmh_168)        AS cnt_lmh_168,
    SUM(a.cnt_lmh_192)        AS cnt_lmh_192,
    SUM(a.cnt_lmh_216)        AS cnt_lmh_216,
    SUM(a.cnt_lmh_240)        AS cnt_lmh_240,
    SUM(a.cnt_lmh_240_plus)   AS cnt_lmh_240_plus
  FROM aggregated a
  GROUP BY
    a.order_date,
    a.delivery_zone_type,
    a.delivery_division_name,
    a.sorted_lmh_bracket
),

division_metrics AS (
  SELECT
    d.order_date,
    NULL::integer AS delivery_hub_id,
    d.delivery_division_name || ' Total' AS delivery_hub_name,
    d.delivery_zone_type,
    d.delivery_division_name,
    d.sorted_lmh_bracket,
    d.sorted_lmh_orders,
    d.cnt_lmh_12,
    d.cnt_lmh_24,
    d.cnt_lmh_48,
    d.cnt_lmh_72,
    d.cnt_lmh_96,
    d.cnt_lmh_120,
    d.cnt_lmh_144,
    d.cnt_lmh_168,
    d.cnt_lmh_192,
    d.cnt_lmh_216,
    d.cnt_lmh_240,
    d.cnt_lmh_240_plus
  FROM division_agg_raw d
),

/*----------------------------------------------------------
  8) Global totals (all zones & divisions combined), per bracket
----------------------------------------------------------*/
global_agg_raw AS (
  SELECT
    a.order_date,
    a.sorted_lmh_bracket,
    SUM(a.sorted_lmh_orders)  AS sorted_lmh_orders,
    SUM(a.cnt_lmh_12)         AS cnt_lmh_12,
    SUM(a.cnt_lmh_24)         AS cnt_lmh_24,
    SUM(a.cnt_lmh_48)         AS cnt_lmh_48,
    SUM(a.cnt_lmh_72)         AS cnt_lmh_72,
    SUM(a.cnt_lmh_96)         AS cnt_lmh_96,
    SUM(a.cnt_lmh_120)        AS cnt_lmh_120,
    SUM(a.cnt_lmh_144)        AS cnt_lmh_144,
    SUM(a.cnt_lmh_168)        AS cnt_lmh_168,
    SUM(a.cnt_lmh_192)        AS cnt_lmh_192,
    SUM(a.cnt_lmh_216)        AS cnt_lmh_216,
    SUM(a.cnt_lmh_240)        AS cnt_lmh_240,
    SUM(a.cnt_lmh_240_plus)   AS cnt_lmh_240_plus
  FROM aggregated a
  GROUP BY
    a.order_date,
    a.sorted_lmh_bracket
),

global_metrics AS (
  SELECT
    g.order_date,
    NULL::integer AS delivery_hub_id,
    'Global Total' AS delivery_hub_name,
    'Global' AS delivery_zone_type,
    NULL::text AS delivery_division_name,
    g.sorted_lmh_bracket,
    g.sorted_lmh_orders,
    g.cnt_lmh_12,
    g.cnt_lmh_24,
    g.cnt_lmh_48,
    g.cnt_lmh_72,
    g.cnt_lmh_96,
    g.cnt_lmh_120,
    g.cnt_lmh_144,
    g.cnt_lmh_168,
    g.cnt_lmh_192,
    g.cnt_lmh_216,
    g.cnt_lmh_240,
    g.cnt_lmh_240_plus
  FROM global_agg_raw g
),

/*----------------------------------------------------------
  9) Combine hub rows + zone totals + division totals + global totals
----------------------------------------------------------*/
combined AS (
  SELECT
    a.order_date,
    a.delivery_hub_id,
    a.delivery_hub_name,
    a.delivery_zone_type,
    a.delivery_division_name,
    a.sorted_lmh_bracket,
    a.sorted_lmh_orders,
    a.cnt_lmh_12,
    a.cnt_lmh_24,
    a.cnt_lmh_48,
    a.cnt_lmh_72,
    a.cnt_lmh_96,
    a.cnt_lmh_120,
    a.cnt_lmh_144,
    a.cnt_lmh_168,
    a.cnt_lmh_192,
    a.cnt_lmh_216,
    a.cnt_lmh_240,
    a.cnt_lmh_240_plus
  FROM aggregated a

  UNION ALL

  SELECT
    z.order_date,
    z.delivery_hub_id,
    z.delivery_hub_name,
    z.delivery_zone_type,
    z.delivery_division_name,
    z.sorted_lmh_bracket,
    z.sorted_lmh_orders,
    z.cnt_lmh_12,
    z.cnt_lmh_24,
    z.cnt_lmh_48,
    z.cnt_lmh_72,
    z.cnt_lmh_96,
    z.cnt_lmh_120,
    z.cnt_lmh_144,
    z.cnt_lmh_168,
    z.cnt_lmh_192,
    z.cnt_lmh_216,
    z.cnt_lmh_240,
    z.cnt_lmh_240_plus
  FROM zone_metrics z

  UNION ALL

  SELECT
    d.order_date,
    d.delivery_hub_id,
    d.delivery_hub_name,
    d.delivery_zone_type,
    d.delivery_division_name,
    d.sorted_lmh_bracket,
    d.sorted_lmh_orders,
    d.cnt_lmh_12,
    d.cnt_lmh_24,
    d.cnt_lmh_48,
    d.cnt_lmh_72,
    d.cnt_lmh_96,
    d.cnt_lmh_120,
    d.cnt_lmh_144,
    d.cnt_lmh_168,
    d.cnt_lmh_192,
    d.cnt_lmh_216,
    d.cnt_lmh_240,
    d.cnt_lmh_240_plus
  FROM division_metrics d

  UNION ALL

  SELECT
    g.order_date,
    g.delivery_hub_id,
    g.delivery_hub_name,
    g.delivery_zone_type,
    g.delivery_division_name,
    g.sorted_lmh_bracket,
    g.sorted_lmh_orders,
    g.cnt_lmh_12,
    g.cnt_lmh_24,
    g.cnt_lmh_48,
    g.cnt_lmh_72,
    g.cnt_lmh_96,
    g.cnt_lmh_120,
    g.cnt_lmh_144,
    g.cnt_lmh_168,
    g.cnt_lmh_192,
    g.cnt_lmh_216,
    g.cnt_lmh_240,
    g.cnt_lmh_240_plus
  FROM global_metrics g
)

/*----------------------------------------------------------
  10) Final select – add FRACTION columns (no *100, Excel will format)
----------------------------------------------------------*/
SELECT
  c.order_date          AS "Order Date",
  c.delivery_hub_id     AS "Last Mile Hub ID",
  c.delivery_hub_name   AS "Last Mile Hub Name",
  c.delivery_zone_type  AS "Last Mile Zone",
  c.delivery_division_name AS "Last Mile Division",

  c.sorted_lmh_bracket  AS "Sorted to LMH Aging Bracket",
  c.sorted_lmh_orders   AS "Sorted to LMH Orders",

  /* LMH→Terminal counts per column bracket */
  c.cnt_lmh_12       AS "LMH to Terminal 12 hrs",
  c.cnt_lmh_24       AS "LMH to Terminal 24 hrs",
  c.cnt_lmh_48       AS "LMH to Terminal 48 hrs",
  c.cnt_lmh_72       AS "LMH to Terminal 72 hrs",
  c.cnt_lmh_96       AS "LMH to Terminal 96 hrs",
  c.cnt_lmh_120      AS "LMH to Terminal 120 hrs",
  c.cnt_lmh_144      AS "LMH to Terminal 144 hrs",
  c.cnt_lmh_168      AS "LMH to Terminal 168 hrs",
  c.cnt_lmh_192      AS "LMH to Terminal 192 hrs",
  c.cnt_lmh_216      AS "LMH to Terminal 216 hrs",
  c.cnt_lmh_240      AS "LMH to Terminal 240 hrs",
  c.cnt_lmh_240_plus AS "LMH to Terminal 240 hrs++",

  /* LMH→Terminal FRACTIONS per column bracket (0–1, row-denominator = Sorted→LMH Orders) */
  ROUND(c.cnt_lmh_12       / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 12 hrs",
  ROUND(c.cnt_lmh_24       / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 24 hrs",
  ROUND(c.cnt_lmh_48       / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 48 hrs",
  ROUND(c.cnt_lmh_72       / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 72 hrs",
  ROUND(c.cnt_lmh_96       / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 96 hrs",
  ROUND(c.cnt_lmh_120      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 120 hrs",
  ROUND(c.cnt_lmh_144      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 144 hrs",
  ROUND(c.cnt_lmh_168      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 168 hrs",
  ROUND(c.cnt_lmh_192      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 192 hrs",
  ROUND(c.cnt_lmh_216      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 216 hrs",
  ROUND(c.cnt_lmh_240      / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 240 hrs",
  ROUND(c.cnt_lmh_240_plus / NULLIF(c.sorted_lmh_orders, 0), 2)
    AS "% LMH to Terminal 240 hrs++"

FROM combined c
ORDER BY
  c.order_date DESC,
  c.delivery_zone_type,
  c.delivery_division_name,
  c.delivery_hub_name,
  CASE c.sorted_lmh_bracket
    WHEN '12 hrs'    THEN 1
    WHEN '24 hrs'    THEN 2
    WHEN '48 hrs'    THEN 3
    WHEN '72 hrs'    THEN 4
    WHEN '96 hrs'    THEN 5
    WHEN '120 hrs'   THEN 6
    WHEN '144 hrs'   THEN 7
    WHEN '168 hrs'   THEN 8
    WHEN '192 hrs'   THEN 9
    WHEN '216 hrs'   THEN 10
    WHEN '240 hrs'   THEN 11
    WHEN '240 hrs++' THEN 12
    ELSE 99
  END;
