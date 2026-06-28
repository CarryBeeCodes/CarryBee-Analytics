/* Hub-level wrong-sorting model with severity score
   + "Total Sends (Zone Transfer Orders)" = only sends on orders that had zone_transfer
   + "Highest Repeat Send" = max wrong sends for a single consignment per hub
   Window: orders with sorted_at (UTC+6) between 1–30 Nov 2025
*/

WITH
-- 1) Candidate orders in the time window
candidate_orders AS (
  SELECT
    o.*
  FROM public.orders o
  WHERE
    (o.sorted_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-01 00:00:00'
    AND (o.sorted_at + INTERVAL '6 hours') <  TIMESTAMP '2025-12-01 00:00:00'
    AND o.transfer_status_id IN (15,17,18,21,22)
    AND o.business_id <> 10
),

/*----------------------------------------------------------
  2) Hub → Zone + Division map (UPDATED)
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

-- 3) Raw zone_transfer logs (only for candidate orders)
zone_transfer_raw AS (
  SELECT
    ol.order_id,
    ol.id AS order_log_id,
    (ol.created_at + INTERVAL '6 hours') AS zone_transfer_time_utc6,
    NULLIF(ol.payload::jsonb ->> 'prev_delivery_hub_id','')::int AS prev_hub_id,
    NULLIF(ol.payload::jsonb ->> 'new_delivery_hub_id','')::int  AS new_hub_id
  FROM public.order_logs ol
  JOIN candidate_orders co
    ON co.id = ol.order_id
  WHERE
    ol.payload::jsonb ->> 'action' = 'zone_transfer'
    AND (ol.created_at + INTERVAL '6 hours') >= TIMESTAMP '2025-11-08 00:00:00'
),

-- 4) Keep only effective transfers (prev <> new) and rank within order
zone_transfer_logs AS (
  SELECT
    ztr.order_id,
    ztr.order_log_id,
    ztr.zone_transfer_time_utc6,
    ztr.prev_hub_id,
    ztr.new_hub_id,
    ROW_NUMBER() OVER (
      PARTITION BY ztr.order_id
      ORDER BY ztr.zone_transfer_time_utc6, ztr.order_log_id
    ) AS rn
  FROM zone_transfer_raw ztr
  WHERE
    ztr.new_hub_id IS NOT NULL
    AND ztr.prev_hub_id IS DISTINCT FROM ztr.new_hub_id
),

-- 5) Attach hub names (optional)
zone_transfer_named AS (
  SELECT
    ztl.order_id,
    ztl.order_log_id,
    ztl.zone_transfer_time_utc6,
    ztl.prev_hub_id,
    ztl.new_hub_id,
    ztl.rn,
    ph.name AS prev_hub_name,
    nh.name AS new_hub_name
  FROM zone_transfer_logs ztl
  LEFT JOIN public.hubs ph ON ph.id = ztl.prev_hub_id
  LEFT JOIN public.hubs nh ON nh.id = ztl.new_hub_id
),

-- 6) Per-order aggregate needed to build pickup → first-prev link
zt_agg AS (
  SELECT
    order_id,
    COUNT(*) AS zone_transfer_count,
    MAX(CASE WHEN rn = 1 THEN prev_hub_id   END) AS first_prev_hub_id,
    MAX(CASE WHEN rn = 1 THEN prev_hub_name END) AS first_prev_hub_name
  FROM zone_transfer_named
  GROUP BY order_id
),

-- 7) All send edges for orders that HAVE zone_transfer
edges_with_zt AS (
  -- (a) Synthetic pickup → first prev, when different
  SELECT
    co.id                AS order_id,
    co.consignment_id,
    co.pickup_hub_id     AS from_hub_id,
    zt.first_prev_hub_id AS to_hub_id
  FROM candidate_orders co
  JOIN zt_agg zt
    ON zt.order_id = co.id
  WHERE
    co.pickup_hub_id IS NOT NULL
    AND zt.first_prev_hub_id IS NOT NULL
    AND co.pickup_hub_id <> zt.first_prev_hub_id

  UNION ALL

  -- (b) All zone_transfer prev → new hops
  SELECT
    ztl.order_id,
    co.consignment_id,
    ztl.prev_hub_id AS from_hub_id,
    ztl.new_hub_id  AS to_hub_id
  FROM zone_transfer_logs ztl
  JOIN candidate_orders co
    ON co.id = ztl.order_id
),

orders_with_zt AS (
  SELECT DISTINCT order_id
  FROM zone_transfer_logs
),

-- 8) Send edges for orders WITHOUT any zone_transfer:
--    treat as a single logical hop pickup → delivery
edges_clean AS (
  SELECT
    co.id              AS order_id,
    co.consignment_id,
    co.pickup_hub_id   AS from_hub_id,
    co.delivery_hub_id AS to_hub_id
  FROM candidate_orders co
  LEFT JOIN orders_with_zt zw
    ON zw.order_id = co.id
  WHERE
    zw.order_id IS NULL
    AND co.pickup_hub_id IS NOT NULL
    AND co.delivery_hub_id IS NOT NULL
    AND co.pickup_hub_id <> co.delivery_hub_id
),

-- 9) All sends in the window (clean + zone-transfer orders)
edges_all AS (
  SELECT * FROM edges_with_zt
  UNION ALL
  SELECT * FROM edges_clean
),

-- 10) Classify each send as correct / wrong / final-hub-wrong
edge_flags AS (
  SELECT
    e.order_id,
    e.consignment_id,
    e.from_hub_id,
    e.to_hub_id,
    co.delivery_hub_id,
    co.pickup_hub_id,
    (co.delivery_hub_id IS NOT NULL
     AND e.to_hub_id IS DISTINCT FROM co.delivery_hub_id) AS is_wrong_send,
    (co.delivery_hub_id IS NOT NULL
     AND e.to_hub_id = co.delivery_hub_id) AS is_correct_send,
    (co.delivery_hub_id IS NOT NULL
     AND e.from_hub_id = co.delivery_hub_id) AS is_final_hub_send
  FROM edges_all e
  JOIN candidate_orders co
    ON co.id = e.order_id
),

-- 11) "Parcel handled" = hub touched the parcel at any stage
processed_touch AS (
  SELECT DISTINCT
    hub_id,
    order_id,
    consignment_id
  FROM (
    -- pickup hub
    SELECT
      co.pickup_hub_id AS hub_id,
      co.id            AS order_id,
      co.consignment_id
    FROM candidate_orders co
    WHERE co.pickup_hub_id IS NOT NULL

    UNION
    -- delivery hub
    SELECT
      co.delivery_hub_id AS hub_id,
      co.id              AS order_id,
      co.consignment_id
    FROM candidate_orders co
    WHERE co.delivery_hub_id IS NOT NULL

    UNION
    -- prev hubs in zone_transfer chain
    SELECT
      ztl.prev_hub_id AS hub_id,
      ztl.order_id    AS order_id,
      co.consignment_id
    FROM zone_transfer_logs ztl
    JOIN candidate_orders co
      ON co.id = ztl.order_id
    WHERE ztl.prev_hub_id IS NOT NULL

    UNION
    -- new hubs in zone_transfer chain
    SELECT
      ztl.new_hub_id AS hub_id,
      ztl.order_id   AS order_id,
      co.consignment_id
    FROM zone_transfer_logs ztl
    JOIN candidate_orders co
      ON co.id = ztl.order_id
    WHERE ztl.new_hub_id IS NOT NULL
  ) t
),

processed_summary AS (
  SELECT
    hub_id,
    COUNT(DISTINCT consignment_id) AS parcels_handled
  FROM processed_touch
  GROUP BY hub_id
),

-- 12) Per-hub send totals (overall / correct / wrong)
send_summary AS (
  SELECT
    from_hub_id AS hub_id,
    COUNT(*) AS sends_total,
    COUNT(*) FILTER (WHERE is_correct_send) AS sends_correct,
    COUNT(*) FILTER (WHERE is_wrong_send)   AS sends_wrong
  FROM edge_flags
  GROUP BY from_hub_id
),

-- 12b) Per-hub sends ONLY on orders that had zone_transfer
--      (synthetic pickup→first-prev + all prev→new hops)
send_summary_zt AS (
  SELECT
    e.from_hub_id AS hub_id,
    COUNT(*)      AS sends_total_zt
  FROM edges_with_zt e
  GROUP BY e.from_hub_id
),

-- 13) Per (hub, order) wrong-send stats to split once vs repeated
hub_order_stats AS (
  SELECT
    from_hub_id AS hub_id,
    order_id,
    COUNT(*) FILTER (WHERE is_wrong_send) AS wrong_send_cnt,
    COUNT(*) FILTER (WHERE is_wrong_send AND is_final_hub_send) AS final_wrong_send_cnt
  FROM edge_flags
  GROUP BY from_hub_id, order_id
),

hub_order_summary AS (
  SELECT
    hub_id,
    SUM(wrong_send_cnt) AS wrong_sends_total,
    SUM(CASE WHEN wrong_send_cnt = 1 THEN 1 ELSE 0 END) AS wrong_sends_once,
    SUM(CASE WHEN wrong_send_cnt > 1 THEN wrong_send_cnt ELSE 0 END) AS wrong_sends_repeated,
    SUM(final_wrong_send_cnt) AS final_hub_wrong_sends_total,
    SUM(CASE WHEN final_wrong_send_cnt > 1 THEN final_wrong_send_cnt ELSE 0 END)
      AS final_hub_wrong_sends_repeated,
    MAX(CASE WHEN wrong_send_cnt > 1 THEN wrong_send_cnt ELSE 0 END)
      AS highest_repeat_send   -- max wrong sends for a single consignment
  FROM hub_order_stats
  GROUP BY hub_id
),

-- 14) Final per-hub aggregation
hub_agg AS (
  SELECT
    h.id  AS hub_id,
    h.name AS hub_name,
    hzm.zone_type,
    hzm.division_name,
    COALESCE(ps.parcels_handled, 0)                 AS parcels_handled,
    COALESCE(ss.sends_total, 0)                     AS sends_total,
    COALESCE(ssz.sends_total_zt, 0)                 AS sends_total_zt,
    COALESCE(ss.sends_correct, 0)                   AS sends_correct,
    COALESCE(ss.sends_wrong, 0)                     AS sends_wrong,
    COALESCE(hos.wrong_sends_once, 0)               AS wrong_sends_once,
    COALESCE(hos.wrong_sends_repeated, 0)           AS wrong_sends_repeated,
    COALESCE(hos.final_hub_wrong_sends_total, 0)    AS final_hub_wrong_sends_total,
    COALESCE(hos.final_hub_wrong_sends_repeated, 0) AS final_hub_wrong_sends_repeated,
    COALESCE(hos.highest_repeat_send, 0)            AS highest_repeat_send
  FROM public.hubs h
  LEFT JOIN hub_zone_map      hzm ON hzm.hub_id = h.id
  LEFT JOIN processed_summary ps  ON ps.hub_id  = h.id
  LEFT JOIN send_summary      ss  ON ss.hub_id  = h.id
  LEFT JOIN send_summary_zt   ssz ON ssz.hub_id = h.id
  LEFT JOIN hub_order_summary hos ON hos.hub_id = h.id
  WHERE ps.parcels_handled IS NOT NULL
     OR ss.sends_total    IS NOT NULL
)

SELECT
  hub_id                            AS "Hub ID",
  hub_name                          AS "Hub Name",
  zone_type                         AS "Zone Type",
  division_name                     AS "Division Name",
  parcels_handled                   AS "Parcels Handled",
  sends_total                       AS "Total Sends (All Orders)",
  sends_total_zt                    AS "Total Sends (Zone Transfer Orders)",
  sends_correct                     AS "Correct Sends",
  sends_wrong                       AS "Wrong Sends",
  wrong_sends_once                  AS "Wrong Sends (Single per Parcel)",
  wrong_sends_repeated              AS "Wrong Sends (Repeated per Parcel)",
  highest_repeat_send               AS "Highest Repeat Send",
  final_hub_wrong_sends_total       AS "Final Hub Wrong Sends",
  final_hub_wrong_sends_repeated    AS "Final Hub Wrong Sends (Repeated)"
  /*(wrong_sends_once
   + 5 * wrong_sends_repeated
   + 10 * final_hub_wrong_sends_total
  )                                 AS "Wrong Sort Severity Score" */
FROM hub_agg
ORDER BY
  --"Wrong Sort Severity Score" DESC,
  "Wrong Sends"               DESC,
  "Hub ID";
