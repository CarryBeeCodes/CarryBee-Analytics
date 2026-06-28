/* ============================================================
Pricing Audit (Business ID = 7446) | Local time = UTC+6

UPDATE:

- COD is now dynamic by 3 buckets: ISD / SUB / OSD
Example rates:
ISD = 1% (0.01)
SUB = 1% (0.01)
OSD = 0% (0.00)

COD bucket rules (your logic):

- SUB: Zone Type = 'ISD to Sub'
- OSD: Zone Type IN ('ISD to OSD','OSD to OSD')
- ISD: Delivery hub zone = ISD AND Is Sub Area = false
============================================================ */

WITH
params AS (
SELECT
7446::int                       AS business_id,

```
/* Example COD rates */
0.01::numeric                   AS cod_rate_isd,  -- 1%
0.01::numeric                   AS cod_rate_sub,  -- 1%
0.00::numeric                   AS cod_rate_osd,  -- 0%

TIMESTAMP '2025-11-01 00:00:00' AS start_local,
TIMESTAMP '2025-12-17 23:59:59' AS end_local

```

),

/* New hub-zone logic */
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

/* Base Price (Tk) */
base_price_chart AS (
SELECT * FROM (VALUES
('Same City'  ,  49,  60,  70,  80,  90, 100, 110, 20),
('ISD to Sub' ,  80,  85, 100, 120, 125, 135, 150, 20),
('ISD to OSD' ,  99, 105, 125, 140, 150, 160, 170, 25),
('OSD to ISD' ,  99, 105, 110, 125, 125, 150, 160, 25),
('OSD to OSD' , 125, 125, 135, 145, 155, 165, 170, 25)
) AS t(type_name, w200, w500, w1000, w1500, w2000, w2500, w3000, over3000_per_1000)
),

/* Discount chart (Tk) */
discount_chart AS (
SELECT * FROM (VALUES
('Same City'  ,   4,  15,  25,  35,  45,  55,  65, 20),
('ISD to Sub' ,  -5,   0,  15,  35,  40,  50,  65, 20),
('ISD to OSD' ,  14,  20,  40,  55,  65,  75,  85, 25),
('OSD to ISD' ,  14,  20,  25,  40,  40,  65,  75, 25),
('OSD to OSD' ,  40,  40,  50,  60,  70,  80,  85, 25)
) AS t(type_name, d200, d500, d1000, d1500, d2000, d2500, d3000, over3000_per_1000)
)

SELECT
/* ================= Required fields ================= */
o.business_id                                             AS "Business ID",
o.consignment_id                                          AS "Consignment ID",
ts.name                                                   AS "Current Status",

(o.sorted_at + INTERVAL '6 hour')                         AS "Sorted at",
(o.transfer_status_updated_at + INTERVAL '6 hour')        AS "Transfer Status Updated at",

ph.name                                                   AS "Pick Up Hub",
COALESCE(phz.zone_type,'OSD')                             AS "Pickup Zone",

dh.name                                                   AS "Delivery Hub",
COALESCE(dhz.zone_type,'OSD')                             AS "Delivery Zone",

c.name                                                    AS "City Name",
z.name                                                    AS "Zone Name",
z.is_sub_area                                             AS "Is Sub Area",

o.price_plan_id                                           AS "Price Plan ID",

o.distance_type                                           AS "Distance ID",
dist.distance_type_name                                   AS "Distance Type",

rt.zone_type                                              AS "Zone Type",

CASE
WHEN rt.zone_type IS NULL OR dist.distance_type_name IS NULL THEN 'Not Matched'
WHEN UPPER(TRIM(rt.zone_type)) = UPPER(TRIM(dist.distance_type_name)) THEN 'Match'
ELSE 'Not Matched'
END                                                       AS "Zone Type Comparision",

o.weight                                                  AS "Weight",

(o.collectable_amount / 100.0)                            AS "Collectable Amount",
(o.collected_amount  / 100.0)                             AS "Collected Amount",

ROUND((o.cod_fee::numeric / 100.0), 2)                    AS "COD Fee",
ROUND((o.delivery_fee::numeric / 100.0), 2)               AS "Delivery Fee",
(o.discount / 100.0)                                      AS "Discount",

ROUND((o.total_fee::numeric / 100.0), 2)                  AS "Total Fee(System)",

/* ================= Calculated outputs ================= */
ROUND(calc.calc_delivery_fee, 2)                          AS "Calculated Delivery Fee",

/* NEW: COD bucket + rate */
codr.cod_bucket                                           AS "COD Criteria",
codr.cod_rate                                             AS "COD Fee %",

ROUND(calc.calc_cod, 2)                                   AS "Calculated COD",
ROUND(calc.calc_discount, 2)                              AS "Calculated Discount",

CASE
WHEN calc.calc_delivery_fee IS NULL
OR calc.calc_cod IS NULL
OR calc.calc_discount IS NULL
THEN NULL::numeric
ELSE ROUND((calc.calc_delivery_fee + calc.calc_cod - calc.calc_discount), 2)
END                                                       AS "Calculated Total Fee",

CASE
WHEN calc.calc_delivery_fee IS NULL
OR calc.calc_cod IS NULL
OR calc.calc_discount IS NULL
THEN NULL::numeric
ELSE ROUND((o.total_fee::numeric / 100.0), 2)
- ROUND((calc.calc_delivery_fee + calc.calc_cod - calc.calc_discount), 2)
END                                                       AS "Total Fee Difference"

FROM orders o
JOIN params p ON TRUE

LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
LEFT JOIN public.hubs ph       ON ph.id = o.pickup_hub_id
LEFT JOIN public.hubs dh       ON dh.id = o.delivery_hub_id

LEFT JOIN hub_zone_map phz     ON phz.hub_id = ph.id
LEFT JOIN hub_zone_map dhz     ON dhz.hub_id = dh.id

LEFT JOIN public.zones  z      ON z.id = o.zone_id
LEFT JOIN public.cities c      ON c.id = o.city_id

/* Distance Type label */
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

/* Normalize ONLY for zone-type rules:
Central Warehouse / Central Inbound treated as ISD. */
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

/* Zone Type logic (priority) */
CROSS JOIN LATERAL (
SELECT
CASE
WHEN ph.id IS NOT NULL AND dh.id IS NOT NULL AND ph.id = dh.id
THEN 'Same City'
WHEN norm.pz = 'ISD' AND norm.is_sub = TRUE
THEN 'ISD to Sub'
WHEN norm.pz = 'ISD' AND norm.dz = 'ISD' AND norm.is_sub = FALSE
THEN 'Same City'
WHEN ph.city_id IS NOT NULL AND dh.city_id IS NOT NULL AND ph.city_id = dh.city_id
THEN 'Same City'
WHEN norm.pz = 'ISD' AND norm.dz IN ('OSD','3PL')
THEN 'ISD to OSD'
WHEN norm.pz = 'ISD' AND norm.dz = 'SUB' AND norm.is_sub = FALSE
THEN 'ISD to OSD'
WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = FALSE
THEN 'OSD to ISD'
WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz IN ('OSD','SUB','3PL')
THEN 'OSD to OSD'
WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = TRUE
THEN 'OSD to OSD'
ELSE NULL
END AS zone_type
) rt

/* NEW: COD bucket + COD rate (dynamic) */
CROSS JOIN LATERAL (
SELECT
CASE
WHEN rt.zone_type = 'ISD to Sub'
THEN 'SUB'
WHEN rt.zone_type IN ('ISD to OSD','OSD to OSD')
THEN 'OSD'
WHEN norm.dz = 'ISD' AND norm.is_sub = FALSE
THEN 'ISD'
ELSE 'OSD'   -- fallback (keeps COD defined; adjust if you want NULL instead)
END AS cod_bucket,

```
CASE
  WHEN rt.zone_type = 'ISD to Sub'
    THEN p.cod_rate_sub
  WHEN rt.zone_type IN ('ISD to OSD','OSD to OSD')
    THEN p.cod_rate_osd
  WHEN norm.dz = 'ISD' AND norm.is_sub = FALSE
    THEN p.cod_rate_isd
  ELSE p.cod_rate_osd
END AS cod_rate

```

) codr

LEFT JOIN base_price_chart bpc ON bpc.type_name = rt.zone_type
LEFT JOIN discount_chart   dc  ON dc.type_name  = rt.zone_type

/* Extra steps ONLY when weight > 3000 */
CROSS JOIN LATERAL (
SELECT
CASE
WHEN o.weight IS NULL THEN NULL::numeric
WHEN o.weight > 3000 THEN CEIL(((o.weight - 3000)::numeric) / 1000.0)
ELSE 0::numeric
END AS extra_steps
) steps

/* Fee calcs */
CROSS JOIN LATERAL (
SELECT
/* Calculated Delivery Fee (Tk) */
(
CASE
WHEN o.weight IS NULL OR bpc.type_name IS NULL THEN NULL::numeric
ELSE CASE
WHEN o.weight <= 200  THEN bpc.w200
WHEN o.weight <= 500  THEN bpc.w500
WHEN o.weight <= 1000 THEN bpc.w1000
WHEN o.weight <= 1500 THEN bpc.w1500
WHEN o.weight <= 2000 THEN bpc.w2000
WHEN o.weight <= 2500 THEN bpc.w2500
WHEN o.weight <= 3000 THEN bpc.w3000
ELSE bpc.w3000 + (bpc.over3000_per_1000 * steps.extra_steps)
END
END
) AS calc_delivery_fee,

```
/* Calculated COD (Tk) — NOW dynamic */
(
  CASE
    WHEN o.collected_amount IS NULL THEN NULL::numeric
    ELSE (o.collected_amount::numeric / 100.0) * codr.cod_rate
  END
) AS calc_cod,

/* Calculated Discount (Tk) */
(
  CASE
    WHEN o.weight IS NULL OR dc.type_name IS NULL THEN NULL::numeric
    ELSE CASE
      WHEN o.weight <= 200  THEN dc.d200
      WHEN o.weight <= 500  THEN dc.d500
      WHEN o.weight <= 1000 THEN dc.d1000
      WHEN o.weight <= 1500 THEN dc.d1500
      WHEN o.weight <= 2000 THEN dc.d2000
      WHEN o.weight <= 2500 THEN dc.d2500
      WHEN o.weight <= 3000 THEN dc.d3000
      ELSE dc.d3000 + (dc.over3000_per_1000 * steps.extra_steps)
    END
  END
) AS calc_discount

```

) calc

WHERE o.business_id = p.business_id
AND (o.sorted_at + INTERVAL '6 hour') BETWEEN p.start_local AND p.end_local
AND o.transfer_status_id NOT IN (1,2,3,6)

/* Exclude Sub Sort Zone hubs completely */
AND o.pickup_hub_id   NOT IN (153,154,155,156,157,158,159)
AND o.delivery_hub_id NOT IN (153,154,155,156,157,158,159)

ORDER BY o.sorted_at DESC;

```sql
/* ============================================================
   Pricing Audit (Business ID = 7446) | Local time = UTC+6

   UPDATE:
   - COD is now dynamic by 3 buckets: ISD / SUB / OSD
     Example rates:
       ISD = 1%  (0.01)
       SUB = 1%  (0.01)
       OSD = 0%  (0.00)

   COD bucket rules (your logic):
   - SUB: Zone Type = 'ISD to Sub'
   - OSD: Zone Type IN ('ISD to OSD','OSD to OSD')
   - ISD: Delivery hub zone = ISD AND Is Sub Area = false
   ============================================================ */

WITH
params AS (
  SELECT
    7446::int                       AS business_id,

    /* Example COD rates */
    0.01::numeric                   AS cod_rate_isd,  -- 1%
    0.01::numeric                   AS cod_rate_sub,  -- 1%
    0.00::numeric                   AS cod_rate_osd,  -- 0%

    TIMESTAMP '2025-11-01 00:00:00' AS start_local,
    TIMESTAMP '2025-12-17 23:59:59' AS end_local
),

/* New hub-zone logic */
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

/* Base Price (Tk) */
base_price_chart AS (
  SELECT * FROM (VALUES
    ('Same City'  ,  49,  60,  70,  80,  90, 100, 110, 20),
    ('ISD to Sub' ,  80,  85, 100, 120, 125, 135, 150, 20),
    ('ISD to OSD' ,  99, 105, 125, 140, 150, 160, 170, 25),
    ('OSD to ISD' ,  99, 105, 110, 125, 125, 150, 160, 25),
    ('OSD to OSD' , 125, 125, 135, 145, 155, 165, 170, 25)
  ) AS t(type_name, w200, w500, w1000, w1500, w2000, w2500, w3000, over3000_per_1000)
),

/* Discount chart (Tk) */
discount_chart AS (
  SELECT * FROM (VALUES
    ('Same City'  ,   4,  15,  25,  35,  45,  55,  65, 20),
    ('ISD to Sub' ,  -5,   0,  15,  35,  40,  50,  65, 20),
    ('ISD to OSD' ,  14,  20,  40,  55,  65,  75,  85, 25),
    ('OSD to ISD' ,  14,  20,  25,  40,  40,  65,  75, 25),
    ('OSD to OSD' ,  40,  40,  50,  60,  70,  80,  85, 25)
  ) AS t(type_name, d200, d500, d1000, d1500, d2000, d2500, d3000, over3000_per_1000)
)

SELECT
  /* ================= Required fields ================= */
  o.business_id                                             AS "Business ID",
  o.consignment_id                                          AS "Consignment ID",
  ts.name                                                   AS "Current Status",

  (o.sorted_at + INTERVAL '6 hour')                         AS "Sorted at",
  (o.transfer_status_updated_at + INTERVAL '6 hour')        AS "Transfer Status Updated at",

  ph.name                                                   AS "Pick Up Hub",
  COALESCE(phz.zone_type,'OSD')                             AS "Pickup Zone",

  dh.name                                                   AS "Delivery Hub",
  COALESCE(dhz.zone_type,'OSD')                             AS "Delivery Zone",

  c.name                                                    AS "City Name",
  z.name                                                    AS "Zone Name",
  z.is_sub_area                                             AS "Is Sub Area",

  o.price_plan_id                                           AS "Price Plan ID",

  o.distance_type                                           AS "Distance ID",
  dist.distance_type_name                                   AS "Distance Type",

  rt.zone_type                                              AS "Zone Type",

  CASE
    WHEN rt.zone_type IS NULL OR dist.distance_type_name IS NULL THEN 'Not Matched'
    WHEN UPPER(TRIM(rt.zone_type)) = UPPER(TRIM(dist.distance_type_name)) THEN 'Match'
    ELSE 'Not Matched'
  END                                                       AS "Zone Type Comparision",

  o.weight                                                  AS "Weight",

  (o.collectable_amount / 100.0)                            AS "Collectable Amount",
  (o.collected_amount  / 100.0)                             AS "Collected Amount",

  ROUND((o.cod_fee::numeric / 100.0), 2)                    AS "COD Fee",
  ROUND((o.delivery_fee::numeric / 100.0), 2)               AS "Delivery Fee",
  (o.discount / 100.0)                                      AS "Discount",

  ROUND((o.total_fee::numeric / 100.0), 2)                  AS "Total Fee(System)",

  /* ================= Calculated outputs ================= */
  ROUND(calc.calc_delivery_fee, 2)                          AS "Calculated Delivery Fee",

  /* NEW: COD bucket + rate */
  codr.cod_bucket                                           AS "COD Criteria",
  codr.cod_rate                                             AS "COD Fee %",

  ROUND(calc.calc_cod, 2)                                   AS "Calculated COD",
  ROUND(calc.calc_discount, 2)                              AS "Calculated Discount",

  CASE
    WHEN calc.calc_delivery_fee IS NULL
      OR calc.calc_cod IS NULL
      OR calc.calc_discount IS NULL
    THEN NULL::numeric
    ELSE ROUND((calc.calc_delivery_fee + calc.calc_cod - calc.calc_discount), 2)
  END                                                       AS "Calculated Total Fee",

  CASE
    WHEN calc.calc_delivery_fee IS NULL
      OR calc.calc_cod IS NULL
      OR calc.calc_discount IS NULL
    THEN NULL::numeric
    ELSE ROUND((o.total_fee::numeric / 100.0), 2)
         - ROUND((calc.calc_delivery_fee + calc.calc_cod - calc.calc_discount), 2)
  END                                                       AS "Total Fee Difference"

FROM orders o
JOIN params p ON TRUE

LEFT JOIN transfer_statuses ts ON ts.id = o.transfer_status_id
LEFT JOIN public.hubs ph       ON ph.id = o.pickup_hub_id
LEFT JOIN public.hubs dh       ON dh.id = o.delivery_hub_id

LEFT JOIN hub_zone_map phz     ON phz.hub_id = ph.id
LEFT JOIN hub_zone_map dhz     ON dhz.hub_id = dh.id

LEFT JOIN public.zones  z      ON z.id = o.zone_id
LEFT JOIN public.cities c      ON c.id = o.city_id

/* Distance Type label */
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

/* Normalize ONLY for zone-type rules:
   Central Warehouse / Central Inbound treated as ISD. */
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
) rt/* Zone Type logic (priority) */
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN ph.id IS NOT NULL AND dh.id IS NOT NULL AND ph.id = dh.id
        THEN 'Same City'
      WHEN norm.pz = 'ISD' AND norm.is_sub = TRUE
        THEN 'ISD to Sub'
      WHEN norm.pz = 'ISD' AND norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'Same City'
      WHEN ph.city_id IS NOT NULL AND dh.city_id IS NOT NULL AND ph.city_id = dh.city_id
        THEN 'Same City'
      WHEN norm.pz = 'ISD' AND norm.dz IN ('OSD','3PL')
        THEN 'ISD to OSD'
      WHEN norm.pz = 'ISD' AND norm.dz = 'SUB' AND norm.is_sub = FALSE
        THEN 'ISD to OSD'
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'OSD to ISD'
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz IN ('OSD','SUB','3PL')
        THEN 'OSD to OSD'
      WHEN norm.pz IN ('OSD','SUB','3PL') AND norm.dz = 'ISD' AND norm.is_sub = TRUE
        THEN 'OSD to OSD'
      ELSE NULL
    END AS zone_type
) rt

/* NEW: COD bucket + COD rate (dynamic) */
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN rt.zone_type = 'ISD to Sub'
        THEN 'SUB'
      WHEN rt.zone_type IN ('ISD to OSD','OSD to OSD')
        THEN 'OSD'
      WHEN norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN 'ISD'
      ELSE 'OSD'   -- fallback (keeps COD defined; adjust if you want NULL instead)
    END AS cod_bucket,

    CASE
      WHEN rt.zone_type = 'ISD to Sub'
        THEN p.cod_rate_sub
      WHEN rt.zone_type IN ('ISD to OSD','OSD to OSD')
        THEN p.cod_rate_osd
      WHEN norm.dz = 'ISD' AND norm.is_sub = FALSE
        THEN p.cod_rate_isd
      ELSE p.cod_rate_osd
    END AS cod_rate
) codr

LEFT JOIN base_price_chart bpc ON bpc.type_name = rt.zone_type
LEFT JOIN discount_chart   dc  ON dc.type_name  = rt.zone_type

/* Extra steps ONLY when weight > 3000 */
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN o.weight IS NULL THEN NULL::numeric
      WHEN o.weight > 3000 THEN CEIL(((o.weight - 3000)::numeric) / 1000.0)
      ELSE 0::numeric
    END AS extra_steps
) steps

/* Fee calcs */
CROSS JOIN LATERAL (
  SELECT
    /* Calculated Delivery Fee (Tk) */
    (
      CASE
        WHEN o.weight IS NULL OR bpc.type_name IS NULL THEN NULL::numeric
        ELSE CASE
          WHEN o.weight <= 200  THEN bpc.w200
          WHEN o.weight <= 500  THEN bpc.w500
          WHEN o.weight <= 1000 THEN bpc.w1000
          WHEN o.weight <= 1500 THEN bpc.w1500
          WHEN o.weight <= 2000 THEN bpc.w2000
          WHEN o.weight <= 2500 THEN bpc.w2500
          WHEN o.weight <= 3000 THEN bpc.w3000
          ELSE bpc.w3000 + (bpc.over3000_per_1000 * steps.extra_steps)
        END
      END
    ) AS calc_delivery_fee,

    /* Calculated COD (Tk) — NOW dynamic */
    (
      CASE
        WHEN o.collected_amount IS NULL THEN NULL::numeric
        ELSE (o.collected_amount::numeric / 100.0) * codr.cod_rate
      END
    ) AS calc_cod,

    /* Calculated Discount (Tk) */
    (
      CASE
        WHEN o.weight IS NULL OR dc.type_name IS NULL THEN NULL::numeric
        ELSE CASE
          WHEN o.weight <= 200  THEN dc.d200
          WHEN o.weight <= 500  THEN dc.d500
          WHEN o.weight <= 1000 THEN dc.d1000
          WHEN o.weight <= 1500 THEN dc.d1500
          WHEN o.weight <= 2000 THEN dc.d2000
          WHEN o.weight <= 2500 THEN dc.d2500
          WHEN o.weight <= 3000 THEN dc.d3000
          ELSE dc.d3000 + (dc.over3000_per_1000 * steps.extra_steps)
        END
      END
    ) AS calc_discount
) calc

WHERE o.business_id = p.business_id
  AND (o.sorted_at + INTERVAL '6 hour') BETWEEN p.start_local AND p.end_local
  AND o.transfer_status_id NOT IN (1,2,3,6)

  /* Exclude Sub Sort Zone hubs completely */
  AND o.pickup_hub_id   NOT IN (153,154,155,156,157,158,159)
  AND o.delivery_hub_id NOT IN (153,154,155,156,157,158,159)

ORDER BY o.sorted_at DESC;

```
