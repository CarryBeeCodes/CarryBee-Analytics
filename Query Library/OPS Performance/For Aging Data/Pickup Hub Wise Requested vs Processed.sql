WITH base AS (
    SELECT
        o.pickup_hub_id,
        h.name AS hub_name,
        o.business_id,
        o.consignment_id,
        o.transfer_status_id
    FROM orders o
    LEFT JOIN hubs h
        ON h.id = o.pickup_hub_id
    WHERE COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hour' >= TIMESTAMP '2026-04-09 00:00:00'
      AND COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hour' <  TIMESTAMP '2026-04-16 00:00:00'
      and o.business_id <> 10
)

SELECT
    pickup_hub_id,
    hub_name,

    COUNT(DISTINCT business_id) FILTER (
        WHERE transfer_status_id IN (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,36,37,38,39)
    ) AS requested_business_id,

    COUNT(DISTINCT business_id) FILTER (
        WHERE transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,37,38,39)
    ) AS processed_business_id,

    COUNT(DISTINCT consignment_id) FILTER (
        WHERE transfer_status_id IN (1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,36,37,38,39)
    ) AS requested_consignment_id,

    COUNT(DISTINCT consignment_id) FILTER (
        WHERE transfer_status_id IN (4,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,37,38,39)
    ) AS processed_consignment_id

FROM base
GROUP BY
    pickup_hub_id,
    hub_name
ORDER BY
    pickup_hub_id;
