/* ============================================================
   Detail rows for Overall IDs Not Closed After Next Day 6 AM

   Required columns:
   - consignment_id
   - transfer_status
   - transfer_status_updated_at
   - delivery_hub_name
   - run_id
   - run_status
   - r.updated_at

   Business time:
   - transfer_status_updated_at + INTERVAL '6 hours'
   - r.updated_at + INTERVAL '6 hours'

   Logic:
   Overall IDs Not Closed After Next Day 6 AM =
   1) Closed After Next Day 6 AM
      run_status = 4
      AND r.updated_at + INTERVAL '6 hours' > next day 6 AM cutoff

   2) Not Closed Run Status
      run_status IN (1,2,3)

   Run type:
   - Delivery run only: r.run_type = 2

   Date range:
   - 25 Apr 2026 to before 29 Apr 2026 in BD time
============================================================ */

WITH latest_delivery_run AS (
    SELECT
        x.order_id,
        x.run_id,
        x.run_status,
        x.run_updated_at
    FROM (
        SELECT
            odr.order_id,
            r.id AS run_id,
            r.run_status,
            (r.updated_at + INTERVAL '6 hours') AS run_updated_at,

            ROW_NUMBER() OVER (
                PARTITION BY odr.order_id
                ORDER BY r.updated_at DESC NULLS LAST, r.id DESC
            ) AS rn

        FROM order_runs odr

        LEFT JOIN runs r
            ON r.id = odr.run_id

        WHERE r.id IS NOT NULL
          AND r.run_type = 2
    ) x
    WHERE x.rn = 1
),

base AS (
    SELECT
        o.id AS order_id,
        o.consignment_id,

        ts.name AS transfer_status,

        (o.transfer_status_updated_at + INTERVAL '6 hours') AS transfer_status_updated_at,

        (
            (o.transfer_status_updated_at + INTERVAL '6 hours')::date
            + INTERVAL '1 day'
            + INTERVAL '6 hours'
        ) AS next_day_6am_cutoff,

        dh.name AS delivery_hub_name,

        ldr.run_id,
        ldr.run_status,
        ldr.run_updated_at

    FROM orders o

    LEFT JOIN transfer_statuses ts
        ON ts.id = o.transfer_status_id

    LEFT JOIN hubs dh
        ON dh.id = o.delivery_hub_id

    LEFT JOIN latest_delivery_run ldr
        ON ldr.order_id = o.id

    WHERE o.transfer_status_id IN (15,17,18,21,22)
      AND o.transfer_status_updated_at IS NOT NULL

      /* Reporting date range in BD time */
      AND (o.transfer_status_updated_at + INTERVAL '6 hours') >= TIMESTAMP '2026-04-25 00:00:00'
      AND (o.transfer_status_updated_at + INTERVAL '6 hours') <  TIMESTAMP '2026-04-30 00:00:00'
)

SELECT
    b.consignment_id AS "consignment_id",

    b.transfer_status AS "transfer_status",

    b.transfer_status_updated_at AS "transfer_status_updated_at",

    b.delivery_hub_name AS "delivery_hub_name",

    b.run_id AS "run_id",

    CASE
        WHEN b.run_status = 1 THEN 'Pending'
        WHEN b.run_status = 2 THEN 'Starting'
        WHEN b.run_status = 3 THEN 'Transferring'
        WHEN b.run_status = 4 THEN 'Closed'
        ELSE 'No Run Found'
    END AS "run_status",

    b.run_updated_at AS "r.updated_at"

FROM base b

WHERE
    (
        b.run_status = 4
        AND b.run_updated_at > b.next_day_6am_cutoff
    )
    OR b.run_status IN (1,2,3)

ORDER BY
    b.transfer_status_updated_at,
    b.delivery_hub_name,
    b.consignment_id;
