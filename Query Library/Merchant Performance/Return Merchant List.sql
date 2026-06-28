/* Plain IN/NOT IN version (no arrays / ANY).
   Uses sorted_at for last 30/7 day windows with BD offset (+6 hours).
*/

WITH base AS (
  SELECT
    o.business_id,
    o.consignment_id,
    o.transfer_status_id,
    o.sorted_at
  FROM orders o
  WHERE o.business_id IS NOT NULL
    AND o.transfer_status_id IN (4,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,35,38,39)
),

per_business AS (
  SELECT
    business_id,

    COUNT(consignment_id) AS "lifetime orders",
    COUNT(consignment_id) FILTER (WHERE transfer_status_id = 17) AS "lifetime return",

    COUNT(consignment_id) FILTER (
      WHERE (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '30 days')
    ) AS "last 30 days orders",

    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '30 days')
    ) AS "last 30 days return",

    COUNT(consignment_id) FILTER (
      WHERE (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '7 days')
    ) AS "last 7 days orders",

    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '7 days')
    ) AS "last 7 days return"

  FROM base
  GROUP BY business_id
),

overall AS (
  SELECT
    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND business_id NOT IN (
          1,2,10,93,96,98,100,101,103,110,111,112,114,118,127,132,134,137,143,146,172,179,262,296,389,
          916,978,984,1441,2055,2398,2520,2963,3762,3840,5237,5378,6201,8046,8050,8051,8086,8230,8252,
          8254,8260,8548,8563,8754,8767,9197,9199,10270,10722,11287,11766,12181,13017
        )
    ) AS "overall lifetime return",

    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND business_id NOT IN (
          1,2,10,93,96,98,100,101,103,110,111,112,114,118,127,132,134,137,143,146,172,179,262,296,389,
          916,978,984,1441,2055,2398,2520,2963,3762,3840,5237,5378,6201,8046,8050,8051,8086,8230,8252,
          8254,8260,8548,8563,8754,8767,9197,9199,10270,10722,11287,11766,12181,13017
        )
        AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '30 days')
    ) AS "overall last 30 days return",

    COUNT(consignment_id) FILTER (
      WHERE transfer_status_id = 17
        AND business_id NOT IN (
          1,2,10,93,96,98,100,101,103,110,111,112,114,118,127,132,134,137,143,146,172,179,262,296,389,
          916,978,984,1441,2055,2398,2520,2963,3762,3840,5237,5378,6201,8046,8050,8051,8086,8230,8252,
          8254,8260,8548,8563,8754,8767,9197,9199,10270,10722,11287,11766,12181,13017
        )
        AND (sorted_at + INTERVAL '6 hours') >= ((NOW() + INTERVAL '6 hours') - INTERVAL '7 days')
    ) AS "overall last 7 days return"
  FROM base
)

SELECT
  pb.business_id,
  pb."lifetime orders",
  pb."lifetime return",
  ov."overall lifetime return",
  pb."last 30 days orders",
  pb."last 30 days return",
  ov."overall last 30 days return",
  pb."last 7 days orders",
  pb."last 7 days return",
  ov."overall last 7 days return"
FROM per_business pb
CROSS JOIN overall ov
ORDER BY pb.business_id;
