/* ============================================================
   Hub-wise terminal orders not closed by next-day 6 AM cutoff

   Business time:
   - Add INTERVAL '6 hours' to all timestamps
   - Reporting date is based on:
     transfer_status_updated_at + INTERVAL '6 hours'

   Logic:
   For each reporting date:
   - cutoff = reporting_date + 1 day + 6 hours
   - Closed After cutoff:
       run_status = 4
       AND run updated_at local time > cutoff
   - Not Closed:
       run_status IN (1,2,3)
   - Overall Not Closed After cutoff:
       Closed After cutoff + Not Closed

   Amount:
   - collected_amount converted from paisa to taka

   Important:
   - Fetches all hubs from hubs table first
   - Orders are assigned based on o.delivery_hub_id
   - Uses latest run per order to avoid duplicate counting
============================================================ */

WITH

/* Hub → region map */
hub_zone_map AS (
    SELECT
        h.id AS hub_id,
        CASE
            -- Dhaka ISD hubs
            WHEN h.id IN (1,2,3,4,5,6,7,8,9,73,92,145,172,193,214)
                THEN 'ISD'

            -- Central Warehouse
            WHEN h.id IN (71,72)
                THEN 'Central Warehouse'

            -- Central Inbound
            WHEN h.id IN (161)
                THEN 'Central Inbound'

            -- Sub Sort zone hubs
            WHEN h.id IN (153,154,155,156,157,158,159)
                THEN 'Sub Sort Zone'

            -- 3PL
            WHEN h.id IN (10)
                THEN '3PL'

            -- SUB hubs
            WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194)
                THEN 'SUB'

            -- Everything else
            ELSE 'OSD'
        END AS region
    FROM hubs h
),

/* Fetch all hubs first */
all_hubs AS (
    SELECT
        h.id AS delivery_hub_id,
        h.name AS delivery_hub_name,
        COALESCE(hzm.region, 'Unknown') AS region
    FROM hubs h
    LEFT JOIN hub_zone_map hzm
        ON hzm.hub_id = h.id
),

/* Dynamic date boundary from terminal orders */
date_bounds AS (
    SELECT
        MIN((o.transfer_status_updated_at + INTERVAL '6 hours')::date) AS start_date,
        MAX((o.transfer_status_updated_at + INTERVAL '6 hours')::date) AS end_date
    FROM orders o
    WHERE o.transfer_status_id IN (15,17,18,21,22)
      AND o.transfer_status_updated_at IS NOT NULL

      /*
        Optional merchant filter if needed:
        AND o.business_id IN (290)
      */

      
        --Optional manual date range if you do not want full OMS history:
        AND (o.transfer_status_updated_at + INTERVAL '6 hours') >= TIMESTAMP '2026-04-25 00:00:00'
        AND (o.transfer_status_updated_at + INTERVAL '6 hours') <  TIMESTAMP '2026-04-30 00:00:00'
      
),

/* Generate all reporting dates dynamically */
reporting_dates AS (
    SELECT
        gs.report_date::date AS report_date,
        (gs.report_date::date + INTERVAL '1 day' + INTERVAL '6 hours') AS next_day_6am_cutoff
    FROM date_bounds db
    CROSS JOIN generate_series(
        db.start_date,
        db.end_date,
        INTERVAL '1 day'
    ) AS gs(report_date)
),

/* Pick latest run per order to avoid duplicate counting */
latest_order_run AS (
    SELECT
        x.order_id,
        x.run_id,
        x.run_type,
        x.run_status,
        x.run_updated_at_local
    FROM (
        SELECT
            odr.order_id,
            r.id AS run_id,
            r.run_type,
            r.run_status,
            (r.updated_at + INTERVAL '6 hours') AS run_updated_at_local,

            ROW_NUMBER() OVER (
                PARTITION BY odr.order_id
                ORDER BY r.updated_at DESC NULLS LAST, r.id DESC
            ) AS rn

        FROM order_runs odr
        LEFT JOIN runs r
            ON r.id = odr.run_id

        WHERE r.id IS NOT NULL

        /*
          Optional: if this report should only check delivery runs,
          uncomment this line:
*/
          AND r.run_type = 2
        
    ) x
    WHERE x.rn = 1
),

/* Terminal orders base */
terminal_orders AS (
    SELECT
        o.id,
        o.consignment_id,
        o.transfer_status_id,
        o.delivery_hub_id,
        o.collected_amount,

        (o.transfer_status_updated_at + INTERVAL '6 hours') AS transfer_status_updated_at_local,
        (o.transfer_status_updated_at + INTERVAL '6 hours')::date AS reporting_date,

        lor.run_id,
        lor.run_type,
        lor.run_status,
        lor.run_updated_at_local

    FROM orders o
    LEFT JOIN latest_order_run lor
        ON lor.order_id = o.id

    WHERE o.transfer_status_id IN (15,17,18,21,22)
      AND o.transfer_status_updated_at IS NOT NULL

      /*
        Optional merchant filter if needed:
        AND o.business_id IN (290)
      */
),

/* Classify by cutoff logic */
classified AS (
    SELECT
        rd.report_date,
        rd.next_day_6am_cutoff,

        ah.region,
        ah.delivery_hub_id,
        ah.delivery_hub_name,

        t.id,
        t.consignment_id,
        t.collected_amount,
        t.run_status,
        t.run_updated_at_local,

        CASE
            WHEN t.run_status = 4
             AND t.run_updated_at_local > rd.next_day_6am_cutoff
                THEN 1
            ELSE 0
        END AS is_closed_after_next_day_6am,

        CASE
            WHEN t.run_status IN (1,2,3)
                THEN 1
            ELSE 0
        END AS is_not_closed_run_status

    FROM reporting_dates rd

    CROSS JOIN all_hubs ah

    LEFT JOIN terminal_orders t
        ON t.reporting_date = rd.report_date
       AND t.delivery_hub_id = ah.delivery_hub_id
)

SELECT
    c.region AS "Region",
    c.delivery_hub_id AS "Delivery Hub ID",
    c.delivery_hub_name AS "Delivery Hub",
    TO_CHAR(c.report_date, 'DD Mon YYYY') AS "Reporting Date",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.is_closed_after_next_day_6am = 1
    ) AS "IDs - Closed After Next Day 6 AM",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.is_not_closed_run_status = 1
    ) AS "IDs - Not Closed After Next Day 6 AM",

    COUNT(DISTINCT c.consignment_id) FILTER (
        WHERE c.is_closed_after_next_day_6am = 1
           OR c.is_not_closed_run_status = 1
    ) AS "Overall IDs Not Closed After Next Day 6 AM",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.is_closed_after_next_day_6am = 1
        ), 0),
        2
    ) AS "Collected Amount - Closed After Next Day 6 AM",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.is_not_closed_run_status = 1
        ), 0),
        2
    ) AS "Collected Amount - Not Closed After Next Day 6 AM",

    ROUND(
        COALESCE(SUM(c.collected_amount::numeric / 100.0) FILTER (
            WHERE c.is_closed_after_next_day_6am = 1
               OR c.is_not_closed_run_status = 1
        ), 0),
        2
    ) AS "Overall Collected Amount Not Closed After Next Day 6 AM"

FROM classified c

GROUP BY
    c.region,
    c.delivery_hub_id,
    c.delivery_hub_name,
    c.report_date

ORDER BY
    c.report_date,
    c.region,
    c.delivery_hub_name;
