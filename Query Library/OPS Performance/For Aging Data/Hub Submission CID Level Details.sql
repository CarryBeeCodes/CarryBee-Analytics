-- /* ============================================================
--    Consignment-level delivered vs submission timing report

--    Source table:
--    - order_invoices

--    Business time:
--    - delivered_at + INTERVAL '6 hours'
--    - submission_at + INTERVAL '6 hours'

--    Reporting date:
--    - Based on delivered_at + INTERVAL '6 hours'

--    Included submission buckets:
--    1) Submission Within Next Day 11 AM
--       submission_at_bd >= next day 00:00:00
--       AND submission_at_bd <= next day 11:00:00

--    2) Submission After Next Day 11 AM
--       submission_at_bd > next day 11:00:00

--    3) Not Submitted Yet
--       submission_at IS NULL

--    No hubs table used.
--    Region is mapped directly from hub_id.
-- ============================================================ */

-- WITH params AS (
--     SELECT
--         DATE '2026-04-25' AS start_date,
--         DATE '2026-04-30' AS end_date
-- ),

-- base AS (
--     SELECT
--         oi.hub_id,

--         CASE
--             -- Dhaka ISD hubs
--             WHEN oi.hub_id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214)
--                 THEN 'ISD'

--             -- Central Warehouse
--             WHEN oi.hub_id IN (71,72)
--                 THEN 'Central Warehouse'

--             -- Central Inbound
--             WHEN oi.hub_id IN (161)
--                 THEN 'Central Inbound'

--             -- Sub Sort zone hubs
--             WHEN oi.hub_id IN (153,154,155,156,157,158,159)
--                 THEN 'Sub Sort Zone'

--             -- 3PL
--             WHEN oi.hub_id IN (10)
--                 THEN '3PL'

--             -- SUB hubs
--             WHEN oi.hub_id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194)
--                 THEN 'SUB'

--             -- Everything else
--             ELSE 'OSD'
--         END AS region,

--         oi.consignment_id,

--         oi.delivered_at + INTERVAL '6 hours' AS delivered_at_bd,
--         (oi.delivered_at + INTERVAL '6 hours')::date AS delivered_date,

--         CASE
--             WHEN oi.submission_at IS NOT NULL
--                 THEN oi.submission_at + INTERVAL '6 hours'
--             ELSE NULL
--         END AS submission_at_bd,

--         oi.collected_amount,
--         oi.total_fee,
--         oi.order_status,

--         /* Next day boundaries based on delivered_at BD date */
--         (oi.delivered_at + INTERVAL '6 hours')::date
--             + INTERVAL '1 day' AS next_day_start,

--         (oi.delivered_at + INTERVAL '6 hours')::date
--             + INTERVAL '1 day'
--             + INTERVAL '11 hours' AS next_day_11am

--     FROM order_invoices oi

--     CROSS JOIN params p

--     WHERE oi.order_status IN (15,17,18,21,22)
--       AND oi.delivered_at IS NOT NULL

--       /* Dynamic delivered_at date filter in BD time */
--       AND oi.delivered_at + INTERVAL '6 hours' >= p.start_date::timestamp
--       AND oi.delivered_at + INTERVAL '6 hours' <  (p.end_date + INTERVAL '1 day')::timestamp
-- ),

-- classified AS (
--     SELECT
--         b.*,

--         CASE
--             WHEN b.submission_at_bd IS NULL
--                 THEN 'Not Submitted Yet'

--             WHEN b.submission_at_bd >= b.next_day_start
--              AND b.submission_at_bd <= b.next_day_11am
--                 THEN 'Submission Within Next Day 11 AM'

--             WHEN b.submission_at_bd > b.next_day_11am
--                 THEN 'Submission After Next Day 11 AM'

--             ELSE 'Outside Required Submission Window'
--         END AS submission_bucket

--     FROM base b
-- )

-- SELECT
--     c.region AS "Region",

--     c.hub_id AS "hub_id",

--     c.consignment_id AS "consignment_id",

--     c.delivered_at_bd AS "delivered_at",

--     c.submission_at_bd AS "submission_at",

--     ROUND((c.collected_amount::numeric / 100.0), 2) AS "collected_amount",

--     ROUND((c.total_fee::numeric / 100.0), 2) AS "total_fee",

--     c.order_status AS "order_status",

--     c.submission_bucket AS "submission_bucket"

-- FROM classified c

-- WHERE c.submission_bucket IN (
--     'Submission Within Next Day 11 AM',
--     'Submission After Next Day 11 AM',
--     'Not Submitted Yet'
-- )

-- ORDER BY
--     c.delivered_date,
--     c.region,
--     c.hub_id,
--     c.submission_bucket,
--     c.delivered_at_bd,
--     c.consignment_id;












/* ============================================================
   Consignment-level delivered vs submission timing report

   Source table:
   - order_invoices

   Business time:
   - delivered_at + INTERVAL '6 hours'
   - submission_at + INTERVAL '6 hours'

   Reporting date:
   - Based on delivered_at + INTERVAL '6 hours'

   Included submission buckets:
   1) Submission Within Next Day 11 AM
      submission_at_bd >= next day 00:00:00
      AND submission_at_bd <= next day 11:00:00

   2) Submission After Next Day 11 AM
      submission_at_bd > next day 11:00:00

   3) Not Submitted Yet
      submission_at IS NULL

   No hubs table used.
   Region is mapped directly from hub_id.
============================================================ */

WITH params AS (
    SELECT
        DATE '2026-04-25' AS start_date,
        DATE '2026-04-30' AS end_date
),

base AS (
    SELECT
        oi.hub_id,

        CASE
            -- Dhaka ISD hubs
            WHEN oi.hub_id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214)
                THEN 'ISD'

            -- Central Warehouse
            WHEN oi.hub_id IN (71,72)
                THEN 'Central Warehouse'

            -- Central Inbound
            WHEN oi.hub_id IN (161)
                THEN 'Central Inbound'

            -- Sub Sort zone hubs
            WHEN oi.hub_id IN (153,154,155,156,157,158,159)
                THEN 'Sub Sort Zone'

            -- 3PL
            WHEN oi.hub_id IN (10)
                THEN '3PL'

            -- SUB hubs
            WHEN oi.hub_id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194)
                THEN 'SUB'

            -- Everything else
            ELSE 'OSD'
        END AS region,

        oi.consignment_id,

        oi.delivered_at + INTERVAL '6 hours' AS delivered_at_bd,
        (oi.delivered_at + INTERVAL '6 hours')::date AS delivered_date,

        CASE
            WHEN oi.submission_at IS NOT NULL
                THEN oi.submission_at + INTERVAL '6 hours'
            ELSE NULL
        END AS submission_at_bd,

        oi.collected_amount,

        oi.total_fee,

        oi.order_status,

        CASE
            WHEN oi.order_status = 15 THEN 'Delivered'
            WHEN oi.order_status = 17 THEN 'Return'
            WHEN oi.order_status = 18 THEN 'Partial Delivery'
            WHEN oi.order_status = 21 THEN 'Paid Return'
            WHEN oi.order_status = 22 THEN 'Exchange'
            ELSE 'Unknown'
        END AS order_status_name,

        /* Next day boundaries based on delivered_at BD date */
        (oi.delivered_at + INTERVAL '6 hours')::date
            + INTERVAL '1 day' AS next_day_start,

        (oi.delivered_at + INTERVAL '6 hours')::date
            + INTERVAL '1 day'
            + INTERVAL '11 hours' AS next_day_11am

    FROM order_invoices oi

    CROSS JOIN params p

    WHERE oi.order_status IN (15,17,18,21,22)
      AND oi.delivered_at IS NOT NULL

      /* Dynamic delivered_at date filter in BD time */
      AND oi.delivered_at + INTERVAL '6 hours' >= p.start_date::timestamp
      AND oi.delivered_at + INTERVAL '6 hours' <  (p.end_date + INTERVAL '1 day')::timestamp
),

classified AS (
    SELECT
        b.*,

        CASE
            WHEN b.submission_at_bd IS NULL
                THEN 'Not Submitted Yet'

            WHEN b.submission_at_bd >= b.next_day_start
             AND b.submission_at_bd <= b.next_day_11am
                THEN 'Submission Within Next Day 11 AM'

            WHEN b.submission_at_bd > b.next_day_11am
                THEN 'Submission After Next Day 11 AM'

            ELSE 'Outside Required Submission Window'
        END AS submission_bucket

    FROM base b
)

SELECT
    c.region AS "Region",

    c.hub_id AS "hub_id",

    c.consignment_id AS "consignment_id",

    c.delivered_at_bd AS "delivered_at",

    c.submission_at_bd AS "submission_at",

    ROUND((c.collected_amount::numeric / 100.0), 2) AS "collected_amount",

    ROUND((c.total_fee::numeric / 100.0), 2) AS "total_fee",

    c.order_status AS "order_status",

    c.order_status_name AS "Order_status_name",

    c.submission_bucket AS "submission_bucket"

FROM classified c

WHERE c.submission_bucket IN (
    'Submission Within Next Day 11 AM',
    'Submission After Next Day 11 AM',
    'Not Submitted Yet'
)

ORDER BY
    c.delivered_date,
    c.region,
    c.hub_id,
    c.submission_bucket,
    c.delivered_at_bd,
    c.consignment_id;
