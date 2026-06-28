/* ============================================================
   Pricing Export for Google Sheet Reconciliation (multi-merchant)
   Local time = UTC + 6

   Added:
   - billing_status_id + Billing status label
   - payment_invoice_id
   - payment_status (Paid/Unpaid)
   ============================================================ */

WITH
params AS (
  SELECT
    /* Put 80 business IDs here */
    ARRAY[
      6190
      -- , ...
    ]::int[] AS business_ids,

    TIMESTAMP '2025-11-01 00:00:00' AS start_local,
    TIMESTAMP '2025-12-28 23:59:59' AS end_local
),

hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145) THEN 'ISD'
      WHEN h.id IN (71,72) THEN 'Central Warehouse'
      WHEN h.id IN (161) THEN 'Central Inbound'
      WHEN h.id IN (153,154,155,156,157,158,159) THEN 'Sub Sort Zone'
      WHEN h.id IN (10) THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
),

base_price_chart AS (
  SELECT * FROM (VALUES
    ('Same City'  ,  49,  60,  70,  80,  90, 100, 110, 20),
    ('ISD to Sub' ,  80,  85, 100, 120, 125, 135, 150, 20),
    ('ISD to OSD' ,  99, 105, 125, 140, 150, 160, 170, 25),
    ('OSD to ISD' ,  99, 105, 110, 125, 125, 150, 160, 25),
    ('OSD to OSD' , 125, 125, 135, 145, 155, 165, 170, 25)
  ) AS t(type_name, w200, w500, w1000, w1500, w2000, w2500, w3000, over3000_per_1000)
)

SELECT
  /* ===== identifiers ===== */
  o.business_id                                  AS business_id,
  --o.business_name                                AS business_name,
  o.consignment_id                               AS consignment_id,

  /* ===== billing/payment fields (NEW) ===== */
  o.billing_status_id                            AS billing_status_id,
  CASE
    WHEN o.billing_status_id IS NULL OR o.billing_status_id = 0 THEN 'Pending'
    WHEN o.billing_status_id = 1 THEN 'Hub Payment Submitted'
    WHEN o.billing_status_id = 2 THEN 'Hub Payment Approved'
    WHEN o.billing_status_id = 3 THEN 'Invoice Unpaid'
    WHEN o.billing_status_id = 4 THEN 'Invoice Processing'
    WHEN o.billing_status_id = 5 THEN 'Invoice Paid'
    ELSE 'Unknown'
  END                                            AS billing_status,

  o.payment_invoice_id                           AS payment_invoice_id,

  CASE
    WHEN o.billing_status_id > 3 AND o.payment_invoice_id IS NOT NULL THEN 'Paid'
    ELSE 'Unpaid'
  END                                            AS payment_status,

  /* ===== status/timestamps ===== */
  ts.name                                        AS current_status,
  o.transfer_status_id                           AS transfer_status_id,

  (o.sorted_at + INTERVAL '6 hour')              AS sorted_at_local,
  (o.transfer_status_updated_at + INTERVAL '6 hour')
                                                 AS transfer_status_updated_at_local,

  /* ===== hubs ===== */
  o.pickup_hub_id,
  ph.name                                        AS pickup_hub_name,

  o.delivery_hub_id,
  dh.name                                        AS delivery_hub_name,

  /* ===== hub zones ===== */
  COALESCE(phz.zone_type,'OSD')                  AS pickup_hub_zone_raw,
  COALESCE(dhz.zone_type,'OSD')                  AS delivery_hub_zone_raw,

  /* ===== destination geo ===== */
  c.name                                         AS city_name,
  z.name                                         AS zone_name,
  COALESCE(z.is_sub_area, FALSE)                 AS is_sub_area,

  /* ===== weight & money (tk) ===== */
  o.weight                                       AS weight_gram,
  (o.collectable_amount / 100.0)                 AS collectable_amount_tk,
  (o.collected_amount  / 100.0)                  AS collected_amount_tk,

  ROUND((o.delivery_fee::numeric / 100.0), 2)    AS delivery_fee_system_tk,
  ROUND((o.cod_fee::numeric      / 100.0), 2)    AS cod_fee_system_tk,
  (o.discount / 100.0)                           AS discount_system_tk,
  ROUND((o.total_fee::numeric    / 100.0), 2)    AS total_fee_system_tk,

  /* ===== distance label from id (optional helper) ===== */
  dist.distance_type_name                        AS distance_type_from_id,

  /* ===== normalized zones ===== */
  norm.pz                                        AS pickup_zone_norm,
  norm.dz                                        AS delivery_zone_norm,

  /* ===== final zone type ===== */
  rt.zone_type                                   AS zone_type,

  /* ===== COD bucket (for sheet lookup) ===== */
  codr.cod_bucket                                AS cod_bucket,

  /* ===== weight slab key (for sheet lookup) ===== */
  slab.weight_slab                               AS weight_slab,

  /* ===== Base Delivery Fee (Tk) ===== */
  ROUND(calc_base.base_delivery_fee_tk, 2)       AS base_delivery_fee_tk,
  calc_base.extra_steps                          AS over3000_steps

FROM orders o
JOIN params p ON TRUE

LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
LEFT JOIN public.hubs ph       ON ph.id = o.pickup_hub_id
LEFT JOIN public.hubs dh       ON dh.id = o.delivery_hub_id

LEFT JOIN hub_zone_map phz     ON phz.hub_id = ph.id
LEFT JOIN hub_zone_map dhz     ON dhz.hub_id = dh.id

LEFT JOIN public.zones  z      ON z.id = o.zone_id
LEFT JOIN public.cities c      ON c.id = o.city_id

CROSS JOIN LATERAL (
  SELECT CASE o.distance_type
    WHEN 1 THEN 'Same City'
    WHEN 2 THEN 'ISD to Sub'
    WHEN 3 THEN 'ISD to OSD'
    WHEN 4 THEN 'OSD to ISD'
    WHEN 5 THEN 'OSD to OSD'
    ELSE NULL
  END AS distance_type_name
) dist

CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN COALESCE(phz.zone_type,'OSD') IN ('Central Warehouse','Central Inbound') THEN 'ISD'
      ELSE COALESCE(phz.zone_type,'OSD')
    END AS pz,
    CASE
      WHEN COALESCE(dhz.zone_type,'OSD') IN ('Central Warehouse','Central Inbound') THEN 'ISD'
      ELSE COALESCE(dhz.zone_type,'OSD')
    END AS dz,
    COALESCE(z.is_sub_area, FALSE) AS is_sub
) norm

/* Zone Type logic (UPDATED with strict overrides) */
CROSS JOIN LATERAL (
  SELECT
    CASE
      /* 0) Same hub id = Same City (still top; no conflict with ISD/SUB combos) */
      WHEN ph.id IS NOT NULL AND dh.id IS NOT NULL AND ph.id = dh.id
        THEN 'Same City'

      /* 1) STRICT: ISD -> SUB always ISD to Sub (no matter what) */
      WHEN norm.pz = 'ISD' AND norm.dz = 'SUB'
        THEN 'ISD to Sub'

      /* 2) STRICT: SUB -> ISD always OSD to ISD (priority over city match & sub-area) */
      WHEN norm.pz = 'SUB' AND norm.dz = 'ISD'
        THEN 'OSD to ISD'

      /* 3) Existing: ISD + destination sub-area => ISD to Sub */
      WHEN norm.pz = 'ISD' AND norm.is_sub = TRUE
        THEN 'ISD to Sub'

      /* 4) Existing: ISD -> ISD & not sub-area => Same City */
      WHEN norm.pz = 'ISD' AND norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'Same City'

      /* 5) Existing: Same City by hub city_id (now lower than strict overrides) */
      WHEN ph.city_id IS NOT NULL AND dh.city_id IS NOT NULL AND ph.city_id = dh.city_id
        THEN 'Same City'

      /* 6) Existing: ISD -> (OSD/3PL) => ISD to OSD */
      WHEN norm.pz = 'ISD' AND norm.dz IN ('OSD','3PL')
        THEN 'ISD to OSD'

      /* 7) Existing: ISD -> SUB but NOT sub-area => previously ISD to OSD
            (won't hit now because strict rule #1 catches ISD->SUB first) */
      WHEN norm.pz = 'ISD' AND norm.dz = 'SUB' AND norm.is_sub = FALSE
        THEN 'ISD to OSD'

      /* 8) Existing: (OSD/SUB/3PL) -> ISD & not sub-area => OSD to ISD
            (SUB->ISD now handled earlier as strict rule #2, even if sub-area) */
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'OSD to ISD'

      /* 9) Existing: (OSD/SUB/3PL) -> (OSD/SUB/3PL) => OSD to OSD */
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz IN ('OSD','SUB','3PL')
        THEN 'OSD to OSD'

      /* 10) Existing: (OSD/SUB/3PL) -> ISD but sub-area => OSD to OSD
             (NOTE: SUB->ISD won’t reach here anymore due to strict rule #2) */
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = TRUE
        THEN 'OSD to OSD'

      ELSE NULL
    END AS zone_type
) rt

CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN rt.zone_type = 'ISD to Sub'
        THEN 'SUB'
      WHEN rt.zone_type IN ('ISD to OSD','OSD to OSD')
        THEN 'OSD'
      WHEN norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'ISD'
      ELSE 'OSD'
    END AS cod_bucket
) codr

CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN o.weight IS NULL THEN NULL
      WHEN o.weight <= 200  THEN '0-200'
      WHEN o.weight <= 500  THEN '201-500'
      WHEN o.weight <= 1000 THEN '501-1000'
      WHEN o.weight <= 1500 THEN '1001-1500'
      WHEN o.weight <= 2000 THEN '1501-2000'
      WHEN o.weight <= 2500 THEN '2001-2500'
      WHEN o.weight <= 3000 THEN '2501-3000'
      ELSE 'OVER_3000'
    END AS weight_slab
) slab

LEFT JOIN base_price_chart bpc ON bpc.type_name = rt.zone_type

CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN o.weight IS NULL OR bpc.type_name IS NULL THEN NULL::numeric
      ELSE
        CASE
          WHEN o.weight <= 200  THEN bpc.w200
          WHEN o.weight <= 500  THEN bpc.w500
          WHEN o.weight <= 1000 THEN bpc.w1000
          WHEN o.weight <= 1500 THEN bpc.w1500
          WHEN o.weight <= 2000 THEN bpc.w2000
          WHEN o.weight <= 2500 THEN bpc.w2500
          WHEN o.weight <= 3000 THEN bpc.w3000
          ELSE
            bpc.w3000
            + (bpc.over3000_per_1000 * CEIL(((o.weight - 3000)::numeric) / 1000.0))
        END
    END AS base_delivery_fee_tk,

    CASE
      WHEN o.weight IS NULL THEN NULL::numeric
      WHEN o.weight > 3000 THEN CEIL(((o.weight - 3000)::numeric) / 1000.0)
      ELSE 0::numeric
    END AS extra_steps
) calc_base

WHERE
  o.business_id = ANY(p.business_ids)
  AND o.business_id <> 10
  AND (o.sorted_at + INTERVAL '6 hour') BETWEEN p.start_local AND p.end_local
  AND o.transfer_status_id NOT IN (1,2,3,6)

  /* Exclude Sub Sort Zone hubs completely */
  AND o.pickup_hub_id   NOT IN (153,154,155,156,157,158,159)
  AND o.delivery_hub_id NOT IN (153,154,155,156,157,158,159)

ORDER BY o.sorted_at DESC;
