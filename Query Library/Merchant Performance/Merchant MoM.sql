/* ============================================================
   Month-wise Orders (Processed / Delivered / Return) - UTC+6 view

   RVN Logic:
   - If transfer_status_id = 17:
       RVN = delivery_fee - discount
   - Else:
       RVN = delivery_fee + cash_on_delivery_fee - discount

   All monetary values are stored in paisa, so divided by 100
   ============================================================ */

WITH params AS (
  SELECT
    TIMESTAMP '2025-10-01 00:00:00' AS start_local,
    TIMESTAMP '2026-06-18 00:00:00' AS end_local_excl,
    (TIMESTAMP '2025-10-01 00:00:00' - INTERVAL '6 hours') AS start_utc,
    (TIMESTAMP '2026-06-18 00:00:00' - INTERVAL '6 hours') AS end_utc_excl
),

base AS (
  SELECT
    o.business_id,
    o.consignment_id,
    o.transfer_status_id,
    o.collected_amount,
    o.collectable_amount,

    -- RVN in paisa
    CASE
      WHEN o.transfer_status_id = 17 THEN
        COALESCE(o.delivery_fee, 0)
        - COALESCE(o.discount, 0)

      ELSE
        COALESCE(o.delivery_fee, 0)
        + COALESCE(o.cod_fee, 0)
        - COALESCE(o.discount, 0)
    END AS rvn_paisa,

    -- BD-local month bucket + BD-local day
    date_trunc('month', o.sorted_at + INTERVAL '6 hours')::date AS month_start_local,
    (o.sorted_at + INTERVAL '6 hours')::date AS sorted_bd_date

  FROM public.orders o
  JOIN params p ON TRUE
  WHERE o.business_id IN (
    7375
  )
    AND o.sorted_at IS NOT NULL
    AND o.sorted_at >= p.start_utc
    AND o.sorted_at <  p.end_utc_excl
    AND o.transfer_status_id IN (
      4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39
    )
)

SELECT
  business_id AS "Business ID",
  month_start_local AS "Month Start (Local)",
  to_char(month_start_local, 'Mon YYYY') AS "Month",

  COUNT(DISTINCT consignment_id) AS "Processed Orders",

  COUNT(DISTINCT CASE 
    WHEN transfer_status_id IN (15,18,21,22)
    THEN consignment_id 
  END) AS "Delivered",

  COUNT(DISTINCT CASE 
    WHEN transfer_status_id = 17
    THEN consignment_id 
  END) AS "Return",

  ROUND(
    100.0 * COUNT(DISTINCT CASE 
      WHEN transfer_status_id IN (15,18,21,22) 
      THEN consignment_id 
    END)
    / NULLIF(COUNT(DISTINCT consignment_id), 0),
    2
  ) AS "Delivery %",

  ROUND(
    100.0 * COUNT(DISTINCT CASE 
      WHEN transfer_status_id = 17 
      THEN consignment_id 
    END)
    / NULLIF(COUNT(DISTINCT consignment_id), 0),
    2
  ) AS "Return %",

  ROUND(SUM(COALESCE(collectable_amount, 0)) / 100.0, 2) AS "Collectable Amount (Tk)",

  ROUND(SUM(COALESCE(collected_amount, 0)) / 100.0, 2) AS "Collected Amount (Tk)",

  ROUND(SUM(COALESCE(rvn_paisa, 0)) / 100.0, 2) AS "RVN (Tk)",

  COUNT(DISTINCT sorted_bd_date) AS "Active Days"

FROM base
GROUP BY business_id, month_start_local
ORDER BY business_id, month_start_local;
