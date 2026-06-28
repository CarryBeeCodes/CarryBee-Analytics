/* ============================================================
   Daily Orders (Processed / Delivered / Return) - UTC+6 view

   Time Filter Options:
   ✅ OPTION A: Last N days (rolling, includes today)  <-- default
   ✅ OPTION B: Fixed start/end local dates            <-- comment A, uncomment B

   Notes:
   - DB timestamps are UTC; grouping is done by BD local date (UTC+6).
   - Filter is applied on o.sorted_at in UTC using converted boundaries.
   ============================================================ */

WITH
settings AS (
  SELECT
    30::int AS last_n_days   -- <-- change to 7 / 15 / N
),

/* ------------------------------
   1) Pick local start/end
--------------------------------*/
params_local AS (
  SELECT
    ((now() AT TIME ZONE 'UTC') + INTERVAL '6 hours') AS local_now,

    /* ✅ OPTION A (rolling last N days, includes today) */
    (date_trunc('day', ((now() AT TIME ZONE 'UTC') + INTERVAL '6 hours'))
      - (settings.last_n_days - 1) * INTERVAL '1 day') AS start_local,
    (date_trunc('day', ((now() AT TIME ZONE 'UTC') + INTERVAL '6 hours'))
      + INTERVAL '1 day') AS end_local_excl

    /* ✅ OPTION B (fixed local range) - uncomment and comment OPTION A above */
    -- TIMESTAMP '2025-04-01 00:00:00' AS start_local,
    -- TIMESTAMP '2026-01-22 00:00:00' AS end_local_excl

  FROM settings
),

/* ------------------------------
   2) Convert to UTC for filtering
--------------------------------*/
params AS (
  SELECT
    start_local,
    end_local_excl,
    (start_local    - INTERVAL '6 hours') AS start_utc,
    (end_local_excl - INTERVAL '6 hours') AS end_utc_excl
  FROM params_local
),

/* ------------------------------
   3) Base dataset (candidate orders)
--------------------------------*/
base AS (
  SELECT
    o.business_id,
    o.consignment_id,
    o.transfer_status_id,
    o.collected_amount,
    o.collectable_amount,
    o.total_fee,

    /* BD local date bucket */
    (o.sorted_at + INTERVAL '6 hours')::date AS sorted_bd_date

  FROM public.orders o
  JOIN params p ON TRUE
  WHERE o.business_id IN (
    586,1081,1086,1411,1413,1511,2207,2227,2229,2294,2312,2314,2328,2364,2724,2742,2792,2861,
    2935,2936,2937,2938,2940,2953,2971,2991,2996,2997,3128,3139,3173,3204,3345,3354,3421,3422,
    3423,3697,3704,3907,4827,5459,5747,6088,6330,6412,6543,7047,7048,7049,7079,7080,7146,7150,
    7212,7214,7287,7367,7446,7628,7755,7763,7767,7878,8559,8630,9490,9791,9992,10282,10345,10766,
    11453,11457,11504,12141,12165,12167,
    14463,14467,14707
  )
    AND o.sorted_at IS NOT NULL
    AND o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc_excl
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
)

SELECT
  business_id                                           AS "Business ID",
  sorted_bd_date                                        AS "Date (Local)",
  to_char(sorted_bd_date, 'DD Mon YYYY')                AS "Date",

  COUNT(DISTINCT consignment_id)                        AS "Processed Orders",
  COUNT(DISTINCT CASE WHEN transfer_status_id IN (15,18,21,22)
                      THEN consignment_id END)          AS "Delivered",
  COUNT(DISTINCT CASE WHEN transfer_status_id = 17
                      THEN consignment_id END)          AS "Return",

  ROUND(
    100.0 * COUNT(DISTINCT CASE WHEN transfer_status_id IN (15,18,21,22) THEN consignment_id END)
    / NULLIF(COUNT(DISTINCT consignment_id), 0)
  , 2)                                                  AS "Delivery %",

  ROUND(
    100.0 * COUNT(DISTINCT CASE WHEN transfer_status_id = 17 THEN consignment_id END)
    / NULLIF(COUNT(DISTINCT consignment_id), 0)
  , 2)                                                  AS "Return %",

  ROUND(SUM(COALESCE(collectable_amount, 0)) / 100.0, 2) AS "Collectable Amount (Tk)",
  ROUND(SUM(COALESCE(collected_amount, 0)) / 100.0, 2)   AS "Collected Amount (Tk)",
  ROUND(SUM(COALESCE(total_fee, 0)) / 100.0, 2)          AS "RVN (Tk)"

FROM base
GROUP BY business_id, sorted_bd_date
ORDER BY business_id, sorted_bd_date;
