WITH
params AS (
  SELECT
    ARRAY[
      161,
      1130,
      1557,
      3649,
      7255,
      8988,
      11283,
      11628,
      11752,
      12167
    ]::int[] AS business_ids,
    1::int AS item_type,
    TIMESTAMP '2026-01-22 00:00:00' AS start_local,
    TIMESTAMP '2026-02-01 00:00:00' AS end_local_excl
),

biz AS (
  SELECT unnest(p.business_ids) AS business_id
  FROM params p
),

base_orders AS (
  SELECT
    o.consignment_id,
    o.business_id,
    o.distance_type,
    (o.sorted_at + INTERVAL '6 hours') AS sorted_at_bd,
    o.weight::numeric AS weight_g,
    o.transfer_status_id,

    ROUND(COALESCE(o.delivery_fee, 0)::numeric / 100.0, 2) AS delivery_fee_tk,
    ROUND(COALESCE(o.discount, 0)::numeric / 100.0, 2) AS discount_tk,
    ROUND(COALESCE(o.cod_fee, 0)::numeric / 100.0, 6) AS cod_fee_tk,
    ROUND(COALESCE(o.collected_amount, 0)::numeric / 100.0, 6) AS collected_amount_tk

  FROM orders o
  JOIN params p ON TRUE
  WHERE o.business_id = ANY(p.business_ids)
    AND o.sorted_at IS NOT NULL
    AND (o.sorted_at + INTERVAL '6 hours') >= p.start_local
    AND (o.sorted_at + INTERVAL '6 hours') <  p.end_local_excl
    AND o.distance_type IN (1,2,3,4,5)
    AND o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
    AND o.weight IS NOT NULL
    AND o.weight > 0
),

classified AS (
  SELECT
    b.*,
    CASE
      WHEN b.weight_g BETWEEN 0 AND 200 THEN '0-200'
      WHEN b.weight_g BETWEEN 201 AND 500 THEN '201-500'
      WHEN b.weight_g BETWEEN 501 AND 1000 THEN '501-1000'
      WHEN b.weight_g BETWEEN 1001 AND 1500 THEN '1001-1500'
      WHEN b.weight_g BETWEEN 1501 AND 2000 THEN '1501-2000'
      WHEN b.weight_g BETWEEN 2001 AND 2500 THEN '2001-2500'
      WHEN b.weight_g BETWEEN 2501 AND 3000 THEN '2501-3000'
      ELSE '3000+'
    END AS weight_slab,
    ROUND(b.delivery_fee_tk - b.discount_tk, 2) AS discounted_fee_tk
  FROM base_orders b
),

under_3kg_counts AS (
  SELECT
    business_id,
    distance_type,
    weight_slab,
    discounted_fee_tk,
    COUNT(*) AS obs_count
  FROM classified
  WHERE weight_slab <> '3000+'
  GROUP BY 1,2,3,4
),

under_3kg_mode AS (
  SELECT
    business_id,
    distance_type,
    weight_slab,
    discounted_fee_tk
  FROM (
    SELECT
      u.*,
      ROW_NUMBER() OVER (
        PARTITION BY u.business_id, u.distance_type, u.weight_slab
        ORDER BY u.obs_count DESC, u.discounted_fee_tk ASC
      ) AS rn
    FROM under_3kg_counts u
  ) x
  WHERE rn = 1
),

under_3kg_pivot AS (
  SELECT
    business_id,
    distance_type,
    MAX(CASE WHEN weight_slab = '0-200' THEN discounted_fee_tk END) AS "0-200",
    MAX(CASE WHEN weight_slab = '201-500' THEN discounted_fee_tk END) AS "201-500",
    MAX(CASE WHEN weight_slab = '501-1000' THEN discounted_fee_tk END) AS "501-1000",
    MAX(CASE WHEN weight_slab = '1001-1500' THEN discounted_fee_tk END) AS "1001-1500",
    MAX(CASE WHEN weight_slab = '1501-2000' THEN discounted_fee_tk END) AS "1501-2000",
    MAX(CASE WHEN weight_slab = '2001-2500' THEN discounted_fee_tk END) AS "2001-2500",
    MAX(CASE WHEN weight_slab = '2501-3000' THEN discounted_fee_tk END) AS "2501-3000"
  FROM under_3kg_mode
  GROUP BY 1,2
),

over_3kg_candidates AS (
  SELECT
    c.business_id,
    c.distance_type,
    c.consignment_id,
    c.weight_g,
    c.discounted_fee_tk,
    p."2501-3000" AS discounted_fee_2501_3000,
    CEIL((c.weight_g - 3000) / 1000.0) AS extra_kg_units,
    ROUND(
      (
        (c.discounted_fee_tk - p."2501-3000")
        / NULLIF(CEIL((c.weight_g - 3000) / 1000.0), 0)
      )::numeric
    , 2) AS per_kg_discounted_fee
  FROM classified c
  JOIN under_3kg_pivot p
    ON p.business_id = c.business_id
   AND p.distance_type = c.distance_type
  WHERE c.weight_slab = '3000+'
    AND p."2501-3000" IS NOT NULL
    AND CEIL((c.weight_g - 3000) / 1000.0) > 0
),

over_3kg_counts AS (
  SELECT
    business_id,
    distance_type,
    per_kg_discounted_fee,
    COUNT(*) AS obs_count
  FROM over_3kg_candidates
  WHERE per_kg_discounted_fee IS NOT NULL
    AND per_kg_discounted_fee >= 0
  GROUP BY 1,2,3
),

over_3kg_mode AS (
  SELECT
    business_id,
    distance_type,
    per_kg_discounted_fee AS "Per KG (After 3kg)"
  FROM (
    SELECT
      o.*,
      ROW_NUMBER() OVER (
        PARTITION BY o.business_id, o.distance_type
        ORDER BY o.obs_count DESC, o.per_kg_discounted_fee ASC
      ) AS rn
    FROM over_3kg_counts o
  ) x
  WHERE rn = 1
),

cod_candidates AS (
  SELECT
    business_id,
    distance_type,
    ROUND((cod_fee_tk / NULLIF(collected_amount_tk, 0))::numeric, 6) AS cod_ratio
  FROM classified
  WHERE collected_amount_tk > 0
),

cod_counts AS (
  SELECT
    business_id,
    distance_type,
    cod_ratio,
    COUNT(*) AS obs_count
  FROM cod_candidates
  GROUP BY 1,2,3
),

cod_mode AS (
  SELECT
    business_id,
    distance_type,
    cod_ratio AS cod_fee
  FROM (
    SELECT
      c.*,
      ROW_NUMBER() OVER (
        PARTITION BY c.business_id, c.distance_type
        ORDER BY c.obs_count DESC, c.cod_ratio ASC
      ) AS rn
    FROM cod_counts c
  ) x
  WHERE rn = 1
),

distance_master AS (
  SELECT 1 AS distance_type, 'Same City' AS "Distance Type"
  UNION ALL SELECT 2, 'ISD to Sub'
  UNION ALL SELECT 3, 'ISD to OSD'
  UNION ALL SELECT 4, 'OSD to ISD'
  UNION ALL SELECT 5, 'OSD to OSD'
)

SELECT
  b.business_id,
  p.item_type,
  d.distance_type,
  d."Distance Type",

  COALESCE(
    u."0-200",
    CASE d.distance_type
      WHEN 1 THEN 49
      WHEN 2 THEN 80
      WHEN 3 THEN 99
      WHEN 4 THEN 99
      WHEN 5 THEN 125
    END
  ) AS "0-200",

  COALESCE(
    u."201-500",
    CASE d.distance_type
      WHEN 1 THEN 60
      WHEN 2 THEN 85
      WHEN 3 THEN 105
      WHEN 4 THEN 105
      WHEN 5 THEN 125
    END
  ) AS "201-500",

  COALESCE(
    u."501-1000",
    CASE d.distance_type
      WHEN 1 THEN 70
      WHEN 2 THEN 100
      WHEN 3 THEN 125
      WHEN 4 THEN 110
      WHEN 5 THEN 135
    END
  ) AS "501-1000",

  COALESCE(
    u."1001-1500",
    CASE d.distance_type
      WHEN 1 THEN 80
      WHEN 2 THEN 120
      WHEN 3 THEN 140
      WHEN 4 THEN 125
      WHEN 5 THEN 145
    END
  ) AS "1001-1500",

  COALESCE(
    u."1501-2000",
    CASE d.distance_type
      WHEN 1 THEN 90
      WHEN 2 THEN 125
      WHEN 3 THEN 150
      WHEN 4 THEN 125
      WHEN 5 THEN 155
    END
  ) AS "1501-2000",

  COALESCE(
    u."2001-2500",
    CASE d.distance_type
      WHEN 1 THEN 100
      WHEN 2 THEN 135
      WHEN 3 THEN 160
      WHEN 4 THEN 150
      WHEN 5 THEN 165
    END
  ) AS "2001-2500",

  COALESCE(
    u."2501-3000",
    CASE d.distance_type
      WHEN 1 THEN 110
      WHEN 2 THEN 150
      WHEN 3 THEN 170
      WHEN 4 THEN 160
      WHEN 5 THEN 170
    END
  ) AS "2501-3000",

  COALESCE(
    o."Per KG (After 3kg)",
    CASE d.distance_type
      WHEN 1 THEN 20
      WHEN 2 THEN 20
      WHEN 3 THEN 25
      WHEN 4 THEN 25
      WHEN 5 THEN 25
    END
  ) AS "Per KG (After 3kg)",

  COALESCE(c.cod_fee, 0.01) AS cod_fee

FROM biz b
CROSS JOIN params p
CROSS JOIN distance_master d
LEFT JOIN under_3kg_pivot u
  ON u.business_id = b.business_id
 AND u.distance_type = d.distance_type
LEFT JOIN over_3kg_mode o
  ON o.business_id = b.business_id
 AND o.distance_type = d.distance_type
LEFT JOIN cod_mode c
  ON c.business_id = b.business_id
 AND c.distance_type = d.distance_type
ORDER BY b.business_id, d.distance_type;
