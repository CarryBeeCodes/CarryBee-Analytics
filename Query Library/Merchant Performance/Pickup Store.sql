WITH ranked_stores AS (
  SELECT
    s.business_id,
    s.id,
    s.name,
    s.address,
    s.contact_person_number,
    s.hub_id,
    ROW_NUMBER() OVER (
      PARTITION BY s.business_id
      ORDER BY s.id
    ) AS rn
  FROM stores s
)

SELECT
  b.id                                      AS "Business ID",
  b.name                                    AS "Business Name",
  b.email                                   AS "Business Email ID",
  b.phone                                   AS "Business Phone",
  b.address                                 AS "Business Address",

  ds.name                                   AS "Default Pickup Store Name",
  ds.address                                AS "Default Pickup Store Address",
  ds.phone                                  AS "Default Pickup Store Number",
  ds.hub_id                                 AS "Default Pickup Hub ID",

  MAX(CASE WHEN rs.rn = 1 THEN rs.name END)    AS "1st Pickup Store",
  MAX(CASE WHEN rs.rn = 1 THEN rs.address END) AS "1st Pickup Store Address",
  MAX(CASE WHEN rs.rn = 1 THEN rs.phone END)   AS "1st Pickup Store Number",
  MAX(CASE WHEN rs.rn = 1 THEN rs.hub_id END)  AS "1st Pickup Store Hub ID",

  MAX(CASE WHEN rs.rn = 2 THEN rs.name END)    AS "2nd Pickup Store",
  MAX(CASE WHEN rs.rn = 2 THEN rs.address END) AS "2nd Pickup Store Address",
  MAX(CASE WHEN rs.rn = 2 THEN rs.phone END)   AS "2nd Pickup Store Number",
  MAX(CASE WHEN rs.rn = 2 THEN rs.hub_id END)  AS "2nd Pickup Store Hub ID",

  MAX(CASE WHEN rs.rn = 3 THEN rs.name END)    AS "3rd Pickup Store",
  MAX(CASE WHEN rs.rn = 3 THEN rs.address END) AS "3rd Pickup Store Address",
  MAX(CASE WHEN rs.rn = 3 THEN rs.phone END)   AS "3rd Pickup Store Number",
  MAX(CASE WHEN rs.rn = 3 THEN rs.hub_id END)  AS "3rd Pickup Store Hub ID",

  MAX(CASE WHEN rs.rn = 4 THEN rs.name END)    AS "4th Pickup Store",
  MAX(CASE WHEN rs.rn = 4 THEN rs.address END) AS "4th Pickup Store Address",
  MAX(CASE WHEN rs.rn = 4 THEN rs.phone END)   AS "4th Pickup Store Number",
  MAX(CASE WHEN rs.rn = 4 THEN rs.hub_id END)  AS "4th Pickup Store Hub ID"

FROM businesses b
LEFT JOIN stores ds
  ON ds.id = b.default_pickup_store_id
LEFT JOIN ranked_stores rs
  ON rs.business_id = b.id
WHERE b.id IN (146,
155,
156,
157,
161,
162,
164,
15744)
GROUP BY
  b.id,
  b.name,
  b.email,
  b.phone,
  b.address,
  ds.name,
  ds.address,
  ds.phone,
  ds.hub_id
ORDER BY b.id;
