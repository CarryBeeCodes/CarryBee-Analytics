SELECT
    b.id  AS business_id,
    b.name AS business_name,
    b.default_pickup_store_id,
    s.name,
    s.hub_id
FROM businesses b
LEFT JOIN stores s
    ON s.id = b.default_pickup_store_id
   AND s.business_id = b.id;
