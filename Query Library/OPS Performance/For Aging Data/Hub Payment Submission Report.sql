/* ============================================================
   Region / Hub / Delivered Date wise submission summary

   Source table:
   - order_invoices

   Business time:
   - delivered_at + INTERVAL '6 hours'
   - submission_at + INTERVAL '6 hours'

   Reporting date:
   - Based on delivered_at + INTERVAL '6 hours'

   Submission buckets:
   1) Submission Within Next Day 11 AM
      submission_at_bd >= next_day 00:00:00
      AND submission_at_bd <= next_day 11:00:00

   2) Submission After Next Day 11 AM
      submission_at_bd > next_day 11:00:00

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
        oi.hub_id AS delivery_hub_id,

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
        oi.order_status

    FROM order_invoices oi

    CROSS JOIN params p

    WHERE oi.order_status IN (15,17,18,21,22)
      AND oi.delivered_at IS NOT NULL

      /* Dynamic delivered date filter in BD time */
      AND oi.delivered_at + INTERVAL '6 hours' >= p.start_date::timestamp
      AND oi.delivered_at + INTERVAL '6 hours' <  (p.end_date + INTERVAL '1 day')::timestamp
),

calc AS (
    SELECT
        b.*,

        /* For delivered_date = 2026-04-27:
           next_day_start = 2026-04-28 00:00:00
           next_day_11am  = 2026-04-28 11:00:00
        */
        b.delivered_date + INTERVAL '1 day' AS next_day_start,

        b.delivered_date + INTERVAL '1 day' + INTERVAL '11 hours' AS next_day_11am

    FROM base b
)

SELECT
    c.region AS "Region",

    c.delivery_hub_id AS "Delivery Hub ID",

    c.delivered_date AS "Delivered Date",

    TO_CHAR(c.delivered_date, 'DD Mon YYYY') AS "Delivered Date Name",

    COUNT(DISTINCT c.consignment_id) AS "Total Delivered IDs",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0), 0),
        2
    ) AS "Total Collected Amount",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.submission_at_bd >= c.next_day_start
          AND c.submission_at_bd <= c.next_day_11am
    ) AS "IDs - Submission Within Next Day 11 AM",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.submission_at_bd >= c.next_day_start
              AND c.submission_at_bd <= c.next_day_11am
        ), 0),
        2
    ) AS "Collected Amount - Submission Within Next Day 11 AM",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.submission_at_bd > c.next_day_11am
    ) AS "IDs - Submission After Next Day 11 AM",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.submission_at_bd > c.next_day_11am
        ), 0),
        2
    ) AS "Collected Amount - Submission After Next Day 11 AM",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.submission_at_bd IS NULL
    ) AS "IDs - Not Submitted Yet",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.submission_at_bd IS NULL
        ), 0),
        2
    ) AS "Collected Amount - Not Submitted Yet"

FROM calc c

GROUP BY
    c.region,
    c.delivery_hub_id,
    c.delivered_date

ORDER BY
    c.delivered_date,
    c.region,
    c.delivery_hub_id;
