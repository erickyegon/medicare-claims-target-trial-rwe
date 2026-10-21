-- Indication scan, step 2: acute conditions (3-character ICD-10 level).
-- First eligible episode per beneficiary and 3-character code, from carrier + outpatient claims:
--   index on/after 2016-03-01, no claim with the same 3-character code in the prior 365 days, age >= 65 on the index date,
--   continuous Part A+B+D from the month containing (index - 365 days) through the index month,
--   no inpatient admission on the index date or the day before.
CREATE OR REPLACE TABLE acute_ep AS
WITH d AS (SELECT DISTINCT BENE_ID, dx3, dt FROM dx_long WHERE src IN ('carrier', 'outpatient')),
l AS (SELECT *, lag(dt) OVER (PARTITION BY BENE_ID, dx3 ORDER BY dt) AS prev_dt FROM d),
e AS (
  SELECT l.BENE_ID, l.dx3, l.dt FROM l JOIN demo ON demo.BENE_ID = l.BENE_ID
  WHERE l.dt >= DATE '2016-03-01'
    AND (l.prev_dt IS NULL OR l.dt - l.prev_dt > 365)
    AND l.dt >= demo.birth + INTERVAL 65 YEAR
    AND EXISTS (SELECT 1 FROM enroll_span s WHERE s.BENE_ID = l.BENE_ID
                AND s.span_start <= date_trunc('month', l.dt - INTERVAL 365 DAY) AND s.span_end >= l.dt)
    AND NOT EXISTS (SELECT 1 FROM adm a WHERE a.BENE_ID = l.BENE_ID AND a.adm_dt BETWEEN l.dt - 1 AND l.dt))
SELECT BENE_ID, dx3, min(dt) AS idx FROM e GROUP BY 1, 2;

CREATE OR REPLACE TABLE acute_codes AS SELECT dx3, count(*) AS n_episodes FROM acute_ep GROUP BY 1 HAVING count(*) >= 300;

-- fills in the 0-2 and 0-7 day windows, split into has_drug_concept (RxNorm resolves the NDC) and unhas_drug_concept
CREATE OR REPLACE TABLE acute_win AS
SELECT e.BENE_ID, e.dx3, e.idx,
  coalesce(bool_or(f.has_drug_concept)     FILTER (WHERE f.fill_dt <= e.idx + 2), FALSE) AS drug02,
  coalesce(bool_or(NOT f.has_drug_concept) FILTER (WHERE f.fill_dt <= e.idx + 2), FALSE) AS nodrug02,
  coalesce(bool_or(f.has_drug_concept), FALSE)     AS drug07,
  coalesce(bool_or(NOT f.has_drug_concept), FALSE) AS nodrug07
FROM acute_ep e JOIN acute_codes c ON c.dx3 = e.dx3
LEFT JOIN fill_drug_flag f ON f.BENE_ID = e.BENE_ID AND f.fill_dt BETWEEN e.idx AND e.idx + 7
GROUP BY 1, 2, 3;

-- top drugs (RxNorm ingredient set) by number of episodes with a fill in the window
CREATE OR REPLACE TABLE acute_top AS
SELECT * FROM (
  SELECT dx3, win, drug_name, n, row_number() OVER (PARTITION BY dx3, win ORDER BY n DESC, drug_name) AS rk FROM (
    SELECT e.dx3, '0-2' AS win, fd.drug_name, count(DISTINCT e.BENE_ID) AS n
    FROM acute_ep e JOIN acute_codes c ON c.dx3 = e.dx3 JOIN fill_drug fd ON fd.BENE_ID = e.BENE_ID AND fd.fill_dt BETWEEN e.idx AND e.idx + 2 GROUP BY ALL
    UNION ALL
    SELECT e.dx3, '0-7', fd.drug_name, count(DISTINCT e.BENE_ID)
    FROM acute_ep e JOIN acute_codes c ON c.dx3 = e.dx3 JOIN fill_drug fd ON fd.BENE_ID = e.BENE_ID AND fd.fill_dt BETWEEN e.idx AND e.idx + 7 GROUP BY ALL))
WHERE rk <= 5;

-- (3-character code x ATC level-4 class) arms: treated = first fill of the class on days 0-2; late = first fill on days 3-30
-- (not comparable to either arm); untreated = no fill of the class on days 0-30.
CREATE OR REPLACE TABLE acute_class AS
WITH tot AS (SELECT dx3, n_episodes FROM acute_codes),
cls AS (
  SELECT e.dx3, c.atc_id, any_value(c.atc_name) AS atc_name,
         count(DISTINCT e.BENE_ID) FILTER (WHERE c.fill_dt <= e.idx + 2) AS n_treated,
         count(DISTINCT e.BENE_ID) AS n_any_0_30
  FROM acute_ep e JOIN acute_codes k ON k.dx3 = e.dx3
  JOIN fill_class c ON c.BENE_ID = e.BENE_ID AND c.fill_dt BETWEEN e.idx AND e.idx + 30
  GROUP BY e.dx3, c.atc_id)
SELECT cls.dx3, atc_id, atc_name, tot.n_episodes, n_treated, n_any_0_30 - n_treated AS n_late,
       tot.n_episodes - n_any_0_30 AS n_untreated, least(n_treated, tot.n_episodes - n_any_0_30) AS min_arm
FROM cls JOIN tot ON tot.dx3 = cls.dx3;
