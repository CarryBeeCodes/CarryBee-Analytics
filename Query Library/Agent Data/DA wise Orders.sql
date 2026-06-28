/* Delivery agent wise distinct consignment count
   Time range (BD local / UTC+6):
     2025-12-21 00:00:00  ->  2026-01-20 23:59:59.999999
   Index-friendly UTC filter: [start_utc, end_utc_excl)
*/

SELECT
  o.delivery_agent_id,
  COUNT(DISTINCT o.consignment_id) AS consignment_cnt
FROM orders o
WHERE
  o.delivery_agent_id IN (122,
2262,
3436,
2275,
2554,
2241,
1574,
1407,
2391,
2180)
  AND o.sorted_at + INTERVAL '6 hours' >= TIMESTAMP '2025-12-21 00:00:00'
  AND o.sorted_at + INTERVAL '6 hours' < TIMESTAMP '2026-01-21 00:00:00'
  
  AND o.transfer_status_id IN (15,18,21,22)
GROUP BY 1


# Attempt Merchant wise:
/* ============================================================
   Aging / Pending Orders Report

   Assignment Source:
   - public.order_logs.description ILIKE '%parcel is assigned for delivery%'

   Output Pattern:
   - attempt 1
   - Note for attempt 1
   - attempt 2
   - Note for attempt 2
   - ...
   - attempt 8
   - Note for attempt 8

   Business Filter:
   - orders.business_id = 18412

   Removed:
   - Added On column
   - Aging bracket-wise filtering
   - Transfer status id filtering
   - Last Attempt Status
   - Last Attempt Status Updated at
============================================================ */

WITH
params AS (
  SELECT
    (NOW() AT TIME ZONE 'UTC') AS now_utc,
    ((NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours') AS now_bd
),

hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145,172,193,214) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
),

base_pre AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,

    COALESCE(phz.zone_type, 'OSD') AS pickup_zone,
    ph.name AS pickup_hub,

    COALESCE(dhz.zone_type, 'OSD') AS delivery_zone,
    dh.name AS delivery_hub,

    o.created_at AS created_at_utc,
    o.sorted_at AS sorted_at_utc,
    o.last_mile_at AS lmh_at_utc,
    o.transfer_status_updated_at AS transfer_status_updated_at_utc,

    o.created_at + INTERVAL '6 hours' AS created_at_bd,
    o.sorted_at + INTERVAL '6 hours' AS sorted_at_bd,
    o.last_mile_at + INTERVAL '6 hours' AS lmh_at_bd,
    o.transfer_status_updated_at + INTERVAL '6 hours' AS transfer_status_updated_at_bd,

    CASE
      WHEN o.transfer_status_id IN (15,17,18,19,20,21,22)
        THEN o.transfer_status_updated_at
      ELSE p.now_utc
    END AS aging_end_at_utc,

    o.transfer_status_id,
    ts.name AS last_system_status,

    o.weight,
    o.recipient_name,
    o.recipient_phone,
    o.remarks,
    o.reason,
    o.reprocess_at

  FROM public.orders o

  JOIN params p
    ON TRUE

  LEFT JOIN public.transfer_statuses ts
         ON ts.id = o.transfer_status_id

  LEFT JOIN public.hubs ph
         ON ph.id = o.pickup_hub_id

  LEFT JOIN hub_zone_map phz
         ON phz.hub_id = ph.id

  LEFT JOIN public.hubs dh
         ON dh.id = o.delivery_hub_id

  LEFT JOIN hub_zone_map dhz
         ON dhz.hub_id = dh.id

  WHERE
        o.business_id = 18412
    AND o.sorted_at <= p.now_utc
),

base AS (
  SELECT
    bp.*,

    CASE
      WHEN bp.sorted_at_utc IS NULL
        OR bp.aging_end_at_utc IS NULL
        THEN NULL

      WHEN EXTRACT(
             EPOCH FROM (
               bp.aging_end_at_utc - bp.sorted_at_utc
             )
           ) >= 240 * 3600
        THEN '10+'

      ELSE GREATEST(
             1,
             FLOOR(
               EXTRACT(
                 EPOCH FROM (
                   bp.aging_end_at_utc - bp.sorted_at_utc
                 )
               ) / 86400
             )::int + 1
           )::text
    END AS current_aging

  FROM base_pre bp
),

/*----------------------------------------------------------
  Assignment Logs

  Each matching order_logs row is one attempt.
----------------------------------------------------------*/
assign_logs AS (
  SELECT
    b.order_id,

    ol.id AS assign_log_id,
    ol.updated_at AS assigned_at_utc,
    ol.updated_at + INTERVAL '6 hours' AS assigned_at_bd,
    (ol.updated_at + INTERVAL '6 hours')::date AS assigned_date_bd,

    ROW_NUMBER() OVER (
      PARTITION BY b.order_id
      ORDER BY ol.updated_at ASC, ol.id ASC
    ) AS attempt_no

  FROM base b

  INNER JOIN public.order_logs ol
          ON ol.order_id = b.order_id

  WHERE
        ol.updated_at <= (SELECT now_utc FROM params)
    AND ol.description ILIKE '%parcel is assigned for delivery%'
),

/*----------------------------------------------------------
  Assigned Dates

  One row per order per assigned BD date.
----------------------------------------------------------*/
assigned_dates AS (
  SELECT
    al.order_id,
    al.assigned_date_bd

  FROM assign_logs al

  GROUP BY
    al.order_id,
    al.assigned_date_bd
),

/*----------------------------------------------------------
  Logs From Each Assigned BD Date

  Used to find note value for that assigned date.
----------------------------------------------------------*/
assigned_day_logs AS (
  SELECT
    ad.order_id,
    ad.assigned_date_bd,

    ol.id AS order_log_id,
    ol.updated_at,
    ol.note

  FROM assigned_dates ad

  INNER JOIN public.order_logs ol
          ON ol.order_id = ad.order_id

  WHERE
        ol.updated_at >= (ad.assigned_date_bd::timestamp - INTERVAL '6 hours')
    AND ol.updated_at <  ((ad.assigned_date_bd::timestamp + INTERVAL '1 day') - INTERVAL '6 hours')
),

/*----------------------------------------------------------
  Latest Non-null Note Per Assigned BD Date

  This note is then mapped to the attempt of that assigned date.
----------------------------------------------------------*/
latest_note_per_assigned_date AS (
  SELECT DISTINCT ON (adl.order_id, adl.assigned_date_bd)
    adl.order_id,
    adl.assigned_date_bd,
    adl.note AS assigned_date_note

  FROM assigned_day_logs adl

  WHERE
        adl.note IS NOT NULL
    AND TRIM(adl.note) <> ''

  ORDER BY
    adl.order_id,
    adl.assigned_date_bd,
    adl.updated_at DESC,
    adl.order_log_id DESC
),

/*----------------------------------------------------------
  Assignment Enriched With Note
----------------------------------------------------------*/
assign_enriched AS (
  SELECT
    al.order_id,
    al.attempt_no,
    al.assigned_at_bd,
    lnpad.assigned_date_note

  FROM assign_logs al

  LEFT JOIN latest_note_per_assigned_date lnpad
         ON lnpad.order_id = al.order_id
        AND lnpad.assigned_date_bd = al.assigned_date_bd
),

/*----------------------------------------------------------
  Pivot Attempts Up To 8
----------------------------------------------------------*/
attempt_pivot AS (
  SELECT
    ae.order_id,

    COUNT(*) AS attempt_count,

    MAX(CASE WHEN ae.attempt_no = 1 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 1",
    MAX(CASE WHEN ae.attempt_no = 1 THEN ae.assigned_date_note END) AS "Note for attempt 1",

    MAX(CASE WHEN ae.attempt_no = 2 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 2",
    MAX(CASE WHEN ae.attempt_no = 2 THEN ae.assigned_date_note END) AS "Note for attempt 2",

    MAX(CASE WHEN ae.attempt_no = 3 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 3",
    MAX(CASE WHEN ae.attempt_no = 3 THEN ae.assigned_date_note END) AS "Note for attempt 3",

    MAX(CASE WHEN ae.attempt_no = 4 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 4",
    MAX(CASE WHEN ae.attempt_no = 4 THEN ae.assigned_date_note END) AS "Note for attempt 4",

    MAX(CASE WHEN ae.attempt_no = 5 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 5",
    MAX(CASE WHEN ae.attempt_no = 5 THEN ae.assigned_date_note END) AS "Note for attempt 5",

    MAX(CASE WHEN ae.attempt_no = 6 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 6",
    MAX(CASE WHEN ae.attempt_no = 6 THEN ae.assigned_date_note END) AS "Note for attempt 6",

    MAX(CASE WHEN ae.attempt_no = 7 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 7",
    MAX(CASE WHEN ae.attempt_no = 7 THEN ae.assigned_date_note END) AS "Note for attempt 7",

    MAX(CASE WHEN ae.attempt_no = 8 THEN TO_CHAR(ae.assigned_at_bd, 'FMMM/FMDD/YYYY HH24:MI:SS') END) AS "attempt 8",
    MAX(CASE WHEN ae.attempt_no = 8 THEN ae.assigned_date_note END) AS "Note for attempt 8"

  FROM assign_enriched ae

  GROUP BY
    ae.order_id
),

zone_transfer_orders AS (
  SELECT DISTINCT
    ol.order_id

  FROM public.order_logs ol

  INNER JOIN base b
          ON b.order_id = ol.order_id

  WHERE ol.description ILIKE '%Zone transfer processed%'
)

SELECT
  b.consignment_id AS "CID",

  b.business_id AS "Business ID",

  b.pickup_zone AS "Pickup Zone",
  b.pickup_hub AS "Pickup Hub",

  b.delivery_zone AS "Delivery Zone",
  b.delivery_hub AS "Delivery Hub",

  b.created_at_bd AS "Created at",
  b.sorted_at_bd AS "Sorted at",
  b.lmh_at_bd AS "LMH at",
  b.transfer_status_updated_at_bd AS "Transfer Status Updated at",

  CASE
    WHEN zto.order_id IS NOT NULL THEN 'Yes'
    ELSE 'No'
  END AS "Zone Transfer",

  b.weight AS "weight",
  b.current_aging AS "Current Aging",

  b.transfer_status_id AS "Transfer Status ID",
  b.last_system_status AS "Last System Status",

  b.recipient_name AS "Customer Name",
  b.recipient_phone AS "Customer Contact #",

  COALESCE(ap.attempt_count, 0) AS "Attempt Count",

  ap."attempt 1",
  ap."Note for attempt 1",

  ap."attempt 2",
  ap."Note for attempt 2",

  ap."attempt 3",
  ap."Note for attempt 3",

  ap."attempt 4",
  ap."Note for attempt 4",

  ap."attempt 5",
  ap."Note for attempt 5",

  ap."attempt 6",
  ap."Note for attempt 6",

  ap."attempt 7",
  ap."Note for attempt 7",

  ap."attempt 8",
  ap."Note for attempt 8",

  NULLIF(
    CONCAT_WS(
      ' | ',
      NULLIF(TRIM(b.remarks), ''),
      NULLIF(TRIM(b.reason), '')
    ),
    ''
  ) AS "remarks_reason_note",

  CASE
    WHEN b.reprocess_at IS NULL THEN 'No'
    ELSE 'Yes'
  END AS "Reprocess"

FROM base b

LEFT JOIN attempt_pivot ap
       ON ap.order_id = b.order_id

LEFT JOIN zone_transfer_orders zto
       ON zto.order_id = b.order_id

ORDER BY
  b.sorted_at_bd DESC NULLS LAST,
  b.created_at_bd DESC NULLS LAST;
  
  
  
  
 Backlog Call Validation:
 /* ============================================================
   Aging / Pending Orders Report

   Attempt Source:
   - Attempts are now based only on order_logs.description
   - Target description:
       "parcel is assigned for delivery"

   Core Logic:
   - Added On = query run date in BD time
   - Attempt Count = count of order_logs rows where description matches
   - Last Assigned at = latest matching order_logs.updated_at + 6 hours
     where assigned BD date is before Added On BD date

   Status Logic:
   - For each candidate assigned date:
       1. Keep all order_logs from that BD date
       2. Find latest row where current_status = 14
       3. Take the immediate next row after that row
       4. That next row gives Last Attempt Status and Last Attempt Status Updated at
       5. Note is fetched separately as latest non-null note from that same date

   Fallback Logic:
   - If latest assigned date has no next row after latest current_status = 14,
     fallback to previous assigned date.
   - If no assigned date has valid status movement after 14:
       Last Assigned at = latest eligible assigned datetime
       Last Attempt Status = blank
       Last Attempt Status Updated at = blank
       Note = blank
============================================================ */

WITH
params AS (
  SELECT
    (NOW() AT TIME ZONE 'UTC') AS now_utc,
    ((NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours') AS now_bd,
    (((NOW() AT TIME ZONE 'UTC') + INTERVAL '6 hours')::date) AS added_on_bd
),

hub_zone_map AS (
  SELECT
    h.id AS hub_id,
    CASE
      WHEN h.id IN (1,2,3,4,5,6,7,8,9,71,72,73,92,145,172,193,214) THEN 'ISD'
      WHEN h.id = 10 THEN '3PL'
      WHEN h.id IN (11,12,13,14,15,16,74,78,81,91,110,111,146,160,162,163,168,185,194) THEN 'SUB'
      ELSE 'OSD'
    END AS zone_type
  FROM public.hubs h
),

base AS (
  SELECT
    o.id AS order_id,
    o.consignment_id,
    o.business_id,

    COALESCE(dhz.zone_type, 'OSD') AS delivery_zone,
    dh.name AS delivery_hub,

    COALESCE(o.sorted_at, o.created_at) AS effective_sorted_at_utc,
    (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours') AS sorted_at_bd,

    ts.name AS last_system_status,

    o.weight,
    o.recipient_name,
    o.recipient_phone,
    o.remarks,
    o.reason,
    o.reprocess_at,

    CASE
      WHEN EXTRACT(
             EPOCH FROM (
               p.now_bd - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
             )
           ) >= 240 * 3600
        THEN '10+'

      ELSE GREATEST(
             1,
             FLOOR(
               EXTRACT(
                 EPOCH FROM (
                   p.now_bd - (COALESCE(o.sorted_at, o.created_at) + INTERVAL '6 hours')
                 )
               ) / 86400
             )::int + 1
           )::text
    END AS current_aging

  FROM public.orders o
  JOIN params p
    ON TRUE

  LEFT JOIN public.transfer_statuses ts
         ON ts.id = o.transfer_status_id

  LEFT JOIN public.hubs dh
         ON dh.id = o.delivery_hub_id

  LEFT JOIN hub_zone_map dhz
         ON dhz.hub_id = dh.id

  WHERE
        o.transfer_status_id IN (4,7,8,9,10,11,12,13,14,16,35,37,38,39)
    AND o.business_id <> 10
    AND COALESCE(o.sorted_at, o.created_at) <= p.now_utc
),

/*----------------------------------------------------------
  1) Attempt Logs from order_logs.description

  Each matched order_logs row counts as one attempt.
----------------------------------------------------------*/
attempt_logs AS (
  SELECT
    b.order_id,

    ol.id AS attempt_log_id,
    ol.updated_at AS assigned_at_utc,
    (ol.updated_at + INTERVAL '6 hours') AS assigned_at_bd,
    (ol.updated_at + INTERVAL '6 hours')::date AS assigned_date_bd

  FROM base b

  INNER JOIN public.order_logs ol
          ON ol.order_id = b.order_id

  WHERE
        ol.updated_at <= (SELECT now_utc FROM params)
    AND ol.description ILIKE '%parcel is assigned for delivery%'
),

/*----------------------------------------------------------
  2) Attempt Count

  If no matching description exists, final output shows 0.
----------------------------------------------------------*/
attempt_count AS (
  SELECT
    al.order_id,
    COUNT(*) AS attempt_count

  FROM attempt_logs al

  GROUP BY
    al.order_id
),

/*----------------------------------------------------------
  3) Candidate Assigned Dates Before Added On

  Important:
  - Only assigned dates before Added On BD date are eligible
    for Last Assigned at.
  - If multiple assignment logs exist on the same BD date,
    keep the latest assigned timestamp from that date.
----------------------------------------------------------*/
candidate_assigned_dates AS (
  SELECT
    al.order_id,
    al.assigned_date_bd,
    MAX(al.assigned_at_utc) AS assigned_at_utc

  FROM attempt_logs al
  JOIN params p
    ON TRUE

  WHERE al.assigned_date_bd < p.added_on_bd

  GROUP BY
    al.order_id,
    al.assigned_date_bd
),

/*----------------------------------------------------------
  4) Latest Eligible Assignment

  Used as final fallback for Last Assigned at if no assigned date
  produces valid status movement after current_status = 14.
----------------------------------------------------------*/
latest_eligible_assignment AS (
  SELECT DISTINCT ON (cad.order_id)
    cad.order_id,
    cad.assigned_date_bd,
    cad.assigned_at_utc

  FROM candidate_assigned_dates cad

  ORDER BY
    cad.order_id,
    cad.assigned_date_bd DESC,
    cad.assigned_at_utc DESC
),

/*----------------------------------------------------------
  5) All order_logs Within Each Candidate Assigned BD Date

  BD date boundary converted back to UTC:
  Example BD date 2026-05-04:
    UTC >= 2026-05-03 18:00:00
    UTC <  2026-05-04 18:00:00
----------------------------------------------------------*/
candidate_day_logs AS (
  SELECT
    cad.order_id,
    cad.assigned_date_bd,
    cad.assigned_at_utc,

    ol.id AS order_log_id,
    ol.current_status,
    ol.updated_at,
    ol.note,

    ROW_NUMBER() OVER (
      PARTITION BY cad.order_id, cad.assigned_date_bd
      ORDER BY ol.updated_at ASC, ol.id ASC
    ) AS rn

  FROM candidate_assigned_dates cad

  INNER JOIN public.order_logs ol
          ON ol.order_id = cad.order_id

  WHERE
        ol.updated_at >= (cad.assigned_date_bd::timestamp - INTERVAL '6 hours')
    AND ol.updated_at <  ((cad.assigned_date_bd::timestamp + INTERVAL '1 day') - INTERVAL '6 hours')
),

/*----------------------------------------------------------
  6) Latest current_status = 14 Row Per Assigned Date

  Important:
  - previous_status is ignored
  - note is ignored here
----------------------------------------------------------*/
latest_status_14_per_date AS (
  SELECT
    order_id,
    assigned_date_bd,
    assigned_at_utc,
    rn AS status_14_rn

  FROM (
    SELECT
      cdl.order_id,
      cdl.assigned_date_bd,
      cdl.assigned_at_utc,
      cdl.rn,

      ROW_NUMBER() OVER (
        PARTITION BY cdl.order_id, cdl.assigned_date_bd
        ORDER BY cdl.updated_at DESC, cdl.order_log_id DESC
      ) AS reverse_rn

    FROM candidate_day_logs cdl

    WHERE cdl.current_status = 14
  ) x

  WHERE reverse_rn = 1
),

/*----------------------------------------------------------
  7) Immediate Next Row After Latest current_status = 14

  Important:
  - This must be the immediate next row
  - No note condition
  - If no immediate next row exists, this assigned date is invalid
----------------------------------------------------------*/
next_status_after_14 AS (
  SELECT
    l14.order_id,
    l14.assigned_date_bd,
    l14.assigned_at_utc,

    next_log.current_status AS last_attempt_status_id,
    next_log.updated_at AS last_attempt_status_updated_at_utc

  FROM latest_status_14_per_date l14

  INNER JOIN LATERAL (
    SELECT
      cdl.current_status,
      cdl.updated_at

    FROM candidate_day_logs cdl

    WHERE
          cdl.order_id = l14.order_id
      AND cdl.assigned_date_bd = l14.assigned_date_bd
      AND cdl.rn = l14.status_14_rn + 1

    LIMIT 1
  ) next_log
    ON TRUE
),

/*----------------------------------------------------------
  8) Latest Non-null Note Per Assigned Date

  Note logic is independent of current_status.
----------------------------------------------------------*/
latest_note_per_date AS (
  SELECT DISTINCT ON (cdl.order_id, cdl.assigned_date_bd)
    cdl.order_id,
    cdl.assigned_date_bd,
    cdl.note AS last_attempt_note

  FROM candidate_day_logs cdl

  WHERE cdl.note IS NOT NULL

  ORDER BY
    cdl.order_id,
    cdl.assigned_date_bd,
    cdl.updated_at DESC,
    cdl.order_log_id DESC
),

/*----------------------------------------------------------
  9) Valid Assigned Dates

  A valid assigned date means:
  - there is a latest current_status = 14 row
  - there is an immediate next row after that 14 row

  If latest assigned date is invalid, this naturally falls back
  to the previous assigned date.
----------------------------------------------------------*/
valid_assigned_dates AS (
  SELECT
    nsa.order_id,
    nsa.assigned_date_bd,
    nsa.assigned_at_utc,

    nsa.last_attempt_status_id,
    nsa.last_attempt_status_updated_at_utc,

    lnpd.last_attempt_note,

    ROW_NUMBER() OVER (
      PARTITION BY nsa.order_id
      ORDER BY nsa.assigned_date_bd DESC, nsa.assigned_at_utc DESC
    ) AS valid_assigned_rank

  FROM next_status_after_14 nsa

  LEFT JOIN latest_note_per_date lnpd
         ON lnpd.order_id = nsa.order_id
        AND lnpd.assigned_date_bd = nsa.assigned_date_bd
),

/*----------------------------------------------------------
  10) Selected Assigned Date

  This gives the assigned date that successfully produced:
  Last Attempt Status + Last Attempt Status Updated at.

  If no valid assigned date exists, this CTE will have no row,
  and final output falls back to latest_eligible_assignment
  only for Last Assigned at.
----------------------------------------------------------*/
selected_assigned_date AS (
  SELECT
    vad.order_id,
    vad.assigned_date_bd,
    vad.assigned_at_utc,

    vad.last_attempt_status_id,
    vad.last_attempt_status_updated_at_utc,
    vad.last_attempt_note

  FROM valid_assigned_dates vad

  WHERE vad.valid_assigned_rank = 1
),

/*----------------------------------------------------------
  11) Zone Transfer Flag
----------------------------------------------------------*/
zone_transfer_orders AS (
  SELECT DISTINCT
    ol.order_id
  FROM public.order_logs ol
  INNER JOIN base b
          ON b.order_id = ol.order_id
  WHERE ol.description ILIKE '%Zone transfer processed%'
)

/*----------------------------------------------------------
  12) Final Report
----------------------------------------------------------*/
SELECT
  TO_CHAR(p.added_on_bd, 'FMMM/FMDD/YYYY') AS "Added On",

  b.consignment_id AS "CID",

  b.delivery_zone AS "Delivery Zone",
  b.delivery_hub AS "Delivery Hub",

  b.business_id AS "Business ID",

  CASE
    WHEN zto.order_id IS NOT NULL THEN 'Yes'
    ELSE 'No'
  END AS "Zone Transfer",

  b.weight AS "weight",
  b.current_aging AS "Current Aging",

  b.last_system_status AS "Last System Status",

  b.recipient_name AS "Customer Name",
  b.recipient_phone AS "Customer Contact #",

  COALESCE(ac.attempt_count, 0) AS "Attempt Count",

  TO_CHAR(
    COALESCE(sad.assigned_at_utc, lea.assigned_at_utc) + INTERVAL '6 hours',
    'FMMM/FMDD/YYYY HH24:MI:SS'
  ) AS "Last Assigned at",

  last_ts.name AS "Last Attempt Status",

  TO_CHAR(
    sad.last_attempt_status_updated_at_utc + INTERVAL '6 hours',
    'FMMM/FMDD/YYYY HH24:MI:SS'
  ) AS "Last Attempt Status Updated at",

  sad.last_attempt_note AS "Note",

  NULLIF(
    CONCAT_WS(
      ' | ',
      NULLIF(TRIM(b.remarks), ''),
      NULLIF(TRIM(b.reason), '')
    ),
    ''
  ) AS "remarks_reason_note",

  CASE
    WHEN b.reprocess_at IS NULL THEN 'No'
    ELSE 'Yes'
  END AS "Reprocess"

FROM base b

JOIN params p
  ON TRUE

LEFT JOIN attempt_count ac
       ON ac.order_id = b.order_id

LEFT JOIN latest_eligible_assignment lea
       ON lea.order_id = b.order_id

LEFT JOIN selected_assigned_date sad
       ON sad.order_id = b.order_id

LEFT JOIN public.transfer_statuses last_ts
       ON last_ts.id = sad.last_attempt_status_id

LEFT JOIN zone_transfer_orders zto
       ON zto.order_id = b.order_id

WHERE
  (
    b.delivery_zone IN ('OSD','3PL')
    AND b.current_aging IN ('6','7','8','9','10','10+')
  )
  OR
  (
    b.delivery_zone IN ('ISD','SUB')
    AND b.current_aging IN ('4','5','6','7','8','9','10','10+')
  )

ORDER BY
  b.sorted_at_bd DESC;
