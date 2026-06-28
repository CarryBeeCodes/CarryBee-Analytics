SELECT
  m.id    AS "Merchant ID",
  m.name  AS "Merchant Name",
  m.email AS "Merchant Email ID",
  m.phone AS "Merchant Phone",

  b.id    AS "Business ID",
  b.name  AS "Business Name",
  b.email AS "Business Email ID",
  b.phone AS "Business Phone",
  b.created_at + interval '6 hours' AS "Business Onboarded Date",
  b.address AS "Business Address",

  s.name    AS "Store Name",
  s.address AS "Store Address"

FROM merchants m
LEFT JOIN business_merchants bm
  ON bm.merchant_id = m.id
LEFT JOIN businesses b
  ON b.id = bm.business_id
LEFT JOIN stores s
  ON s.business_id = b.id

ORDER BY m.id, b.id, s.id;
