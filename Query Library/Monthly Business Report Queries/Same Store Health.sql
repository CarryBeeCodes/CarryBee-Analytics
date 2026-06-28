WITH

-- -----------------------------------------
-- 0) Parameters (May–Dec 2025 + BD timezone)
-- -----------------------------------------
limits AS (
  SELECT
    -- BD month windows (inclusive day ranges)
    DATE '2025-05-01' AS may_from,  DATE '2025-05-31' AS may_to,
    DATE '2025-06-01' AS jun_from,  DATE '2025-06-30' AS jun_to,
    DATE '2025-07-01' AS jul_from,  DATE '2025-07-31' AS jul_to,
    DATE '2025-08-01' AS aug_from,  DATE '2025-08-31' AS aug_to,
    DATE '2025-09-01' AS sep_from,  DATE '2025-09-30' AS sep_to,
    DATE '2025-10-01' AS oct_from,  DATE '2025-10-31' AS oct_to,
    DATE '2025-11-01' AS nov_from,  DATE '2025-11-30' AS nov_to,
    DATE '2025-12-01' AS dec_from,  DATE '2025-12-31' AS dec_to,

    -- First-order cohort cutoffs (16th of prior month)
    DATE '2025-04-16' AS may_cutoff,  -- May cohort:      16-Apr .. 31-May
    DATE '2025-05-16' AS jun_cutoff,  -- June cohort:     16-May .. 30-Jun
    DATE '2025-06-16' AS jul_cutoff,  -- July cohort:     16-Jun .. 31-Jul
    DATE '2025-07-16' AS aug_cutoff,  -- August cohort:   16-Jul .. 31-Aug
    DATE '2025-08-16' AS sep_cutoff,  -- September cohort:16-Aug .. 30-Sep
    DATE '2025-09-16' AS oct_cutoff,  -- October cohort:  16-Sep .. 31-Oct
    DATE '2025-10-16' AS nov_cutoff,  -- November cohort: 16-Oct .. 30-Nov
    DATE '2025-11-16' AS dec_cutoff   -- December cohort: 16-Nov .. 31-Dec
),

-- -----------------------------------------
-- 1) Valid orders (status filter + BD local day)
--    + index-friendly sorted_at bound (UTC)
-- -----------------------------------------
valid_orders AS (
  SELECT
    o.id,
    o.business_id,
    (o.sorted_at + INTERVAL '6 hours')::date AS sorted_date_bd,
    o.transfer_status_id,
    o.transfer_status_updated_at,
    o.consignment_id,
    (
      COALESCE(o.delivery_fee, 0)
      + COALESCE(o.cod_fee, 0)
      + COALESCE(o.additional_charge, 0)
      - COALESCE(o.discount, 0)
    ) / 100.0::numeric AS revenue_tk
  FROM oms.orders o
  CROSS JOIN limits l
  WHERE o.transfer_status_id IN (15,17,18,21,22)
    AND o.transfer_status_updated_at IS NOT NULL
    AND o.sorted_at IS NOT NULL
    -- Overall bound: local [2025-05-01 00:00, 2026-01-01 00:00) => UTC [.. -6h]
    AND o.sorted_at >= (l.may_from::timestamp - INTERVAL '6 hours')
    AND o.sorted_at <  ((l.dec_to + 1)::timestamp - INTERVAL '6 hours')
),

-- -----------------------------------------
-- 2) Business spine (all businesses with ≥1 valid order)
-- -----------------------------------------
business_base AS (
  SELECT DISTINCT
    vo.business_id
  FROM valid_orders vo
),

-- First order (BD) per business
first_order AS (
  SELECT
    vo.business_id,
    MIN(vo.sorted_date_bd) AS first_order_date_bd
  FROM valid_orders vo
  GROUP BY vo.business_id
),

-- -----------------------------------------
-- 3) Monthly order/revenue rollups (May–Dec)
-- -----------------------------------------
monthly AS (
  SELECT
    bb.business_id,

    -- May
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.may_from AND l.may_to THEN vo.consignment_id END) AS orders_may,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.may_from AND l.may_to THEN vo.revenue_tk      END) AS revenue_may_tk,

    -- June
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.jun_from AND l.jun_to THEN vo.consignment_id END) AS orders_june,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.jun_from AND l.jun_to THEN vo.revenue_tk      END) AS revenue_june_tk,

    -- July
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.jul_from AND l.jul_to THEN vo.consignment_id END) AS orders_july,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.jul_from AND l.jul_to THEN vo.revenue_tk      END) AS revenue_july_tk,

    -- August
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.aug_from AND l.aug_to THEN vo.consignment_id END) AS orders_august,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.aug_from AND l.aug_to THEN vo.revenue_tk      END) AS revenue_august_tk,

    -- September
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.sep_from AND l.sep_to THEN vo.consignment_id END) AS orders_september,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.sep_from AND l.sep_to THEN vo.revenue_tk      END) AS revenue_september_tk,

    -- October
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.oct_from AND l.oct_to THEN vo.consignment_id END) AS orders_october,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.oct_from AND l.oct_to THEN vo.revenue_tk      END) AS revenue_october_tk,

    -- November
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.nov_from AND l.nov_to THEN vo.consignment_id END) AS orders_november,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.nov_from AND l.nov_to THEN vo.revenue_tk      END) AS revenue_november_tk,

    -- December
    COUNT(DISTINCT CASE WHEN vo.sorted_date_bd BETWEEN l.dec_from AND l.dec_to THEN vo.consignment_id END) AS orders_december,
    SUM(                CASE WHEN vo.sorted_date_bd BETWEEN l.dec_from AND l.dec_to THEN vo.revenue_tk      END) AS revenue_december_tk

  FROM business_base bb
  CROSS JOIN limits l
  LEFT JOIN valid_orders vo
    ON vo.business_id = bb.business_id
   AND vo.sorted_date_bd BETWEEN l.may_from AND l.dec_to
  GROUP BY bb.business_id
),

-- -----------------------------------------
-- 4) First-order month flag (cohort by FIRST ORDER)
-- -----------------------------------------
first_order_month_flag AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.may_cutoff AND l.may_to THEN 'May'
      WHEN fo.first_order_date_bd BETWEEN l.jun_cutoff AND l.jun_to THEN 'June'
      WHEN fo.first_order_date_bd BETWEEN l.jul_cutoff AND l.jul_to THEN 'July'
      WHEN fo.first_order_date_bd BETWEEN l.aug_cutoff AND l.aug_to THEN 'August'
      WHEN fo.first_order_date_bd BETWEEN l.sep_cutoff AND l.sep_to THEN 'September'
      WHEN fo.first_order_date_bd BETWEEN l.oct_cutoff AND l.oct_to THEN 'October'
      WHEN fo.first_order_date_bd BETWEEN l.nov_cutoff AND l.nov_to THEN 'November'
      WHEN fo.first_order_date_bd BETWEEN l.dec_cutoff AND l.dec_to THEN 'December'
      ELSE NULL
    END AS first_order_month_flag
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  CROSS JOIN limits l
),

-- -----------------------------------------
-- 5) Business type per month (FIRST ORDER–based)
--     New  = first order ∈ [cutoff, month_end]
--     KAM  = first order < cutoff AND has >=1 order that month
-- -----------------------------------------
may_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.may_cutoff AND l.may_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.may_cutoff AND COALESCE(mon.orders_may,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_may
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

june_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.jun_cutoff AND l.jun_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.jun_cutoff AND COALESCE(mon.orders_june,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_june
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

july_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.jul_cutoff AND l.jul_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.jul_cutoff AND COALESCE(mon.orders_july,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_july
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

august_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.aug_cutoff AND l.aug_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.aug_cutoff AND COALESCE(mon.orders_august,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_august
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

september_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.sep_cutoff AND l.sep_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.sep_cutoff AND COALESCE(mon.orders_september,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_september
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

october_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.oct_cutoff AND l.oct_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.oct_cutoff AND COALESCE(mon.orders_october,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_october
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

november_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.nov_cutoff AND l.nov_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.nov_cutoff AND COALESCE(mon.orders_november,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_november
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
),

december_typing AS (
  SELECT
    bb.business_id,
    CASE
      WHEN fo.first_order_date_bd BETWEEN l.dec_cutoff AND l.dec_to THEN 'New Merchant'
      WHEN fo.first_order_date_bd < l.dec_cutoff AND COALESCE(mon.orders_december,0) > 0 THEN 'KAM Merchant'
      ELSE NULL
    END AS merchant_type_in_december
  FROM business_base bb
  LEFT JOIN first_order fo ON fo.business_id = bb.business_id
  JOIN monthly mon ON mon.business_id = bb.business_id
  CROSS JOIN limits l
)

-- -----------------------------------------
-- Final SELECT (May–Dec)
-- -----------------------------------------
SELECT
  bb.business_id,
  fo.first_order_date_bd         AS first_order_date,
  fomf.first_order_month_flag,

  mt_may.merchant_type_in_may,
  mt_jun.merchant_type_in_june,
  mt_jul.merchant_type_in_july,
  mt_aug.merchant_type_in_august,
  mt_sep.merchant_type_in_september,
  mt_oct.merchant_type_in_october,
  mt_nov.merchant_type_in_november,
  mt_dec.merchant_type_in_december,

  COALESCE(mon.orders_may,        0) AS orders_may,
  COALESCE(mon.orders_june,       0) AS orders_june,
  COALESCE(mon.orders_july,       0) AS orders_july,
  COALESCE(mon.orders_august,     0) AS orders_august,
  COALESCE(mon.orders_september,  0) AS orders_september,
  COALESCE(mon.orders_october,    0) AS orders_october,
  COALESCE(mon.orders_november,   0) AS orders_november,
  COALESCE(mon.orders_december,   0) AS orders_december,

  COALESCE(mon.revenue_may_tk,       0)::numeric(18,2) AS revenue_may_tk,
  COALESCE(mon.revenue_june_tk,      0)::numeric(18,2) AS revenue_june_tk,
  COALESCE(mon.revenue_july_tk,      0)::numeric(18,2) AS revenue_july_tk,
  COALESCE(mon.revenue_august_tk,    0)::numeric(18,2) AS revenue_august_tk,
  COALESCE(mon.revenue_september_tk, 0)::numeric(18,2) AS revenue_september_tk,
  COALESCE(mon.revenue_october_tk,   0)::numeric(18,2) AS revenue_october_tk,
  COALESCE(mon.revenue_november_tk,  0)::numeric(18,2) AS revenue_november_tk,
  COALESCE(mon.revenue_december_tk,  0)::numeric(18,2) AS revenue_december_tk

FROM business_base bb
LEFT JOIN first_order fo               ON fo.business_id = bb.business_id
LEFT JOIN monthly mon                  ON mon.business_id = bb.business_id
LEFT JOIN first_order_month_flag fomf  ON fomf.business_id = bb.business_id
LEFT JOIN may_typing mt_may            ON mt_may.business_id = bb.business_id
LEFT JOIN june_typing mt_jun           ON mt_jun.business_id = bb.business_id
LEFT JOIN july_typing mt_jul           ON mt_jul.business_id = bb.business_id
LEFT JOIN august_typing mt_aug         ON mt_aug.business_id = bb.business_id
LEFT JOIN september_typing mt_sep      ON mt_sep.business_id = bb.business_id
LEFT JOIN october_typing mt_oct        ON mt_oct.business_id = bb.business_id
LEFT JOIN november_typing mt_nov       ON mt_nov.business_id = bb.business_id
LEFT JOIN december_typing mt_dec       ON mt_dec.business_id = bb.business_id
ORDER BY bb.business_id;
