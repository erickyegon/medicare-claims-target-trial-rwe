-- Indication scan, step 3: chronic new users by ATC level-4 drug class.
-- New user = first fill of the class on/after 2016-03-01 with no fill of that class in the prior 365 days, age >= 65 at the fill,
-- continuous Part A+B+D from the month containing (fill - 365 days) through the fill month. One index per beneficiary and class.
CREATE OR REPLACE TABLE nu AS
WITH f AS (SELECT DISTINCT BENE_ID, atc_id, fill_dt FROM fill_class),
l AS (SELECT *, lag(fill_dt) OVER (PARTITION BY BENE_ID, atc_id ORDER BY fill_dt) AS prev FROM f),
e AS (
  SELECT l.BENE_ID, l.atc_id, l.fill_dt FROM l JOIN demo ON demo.BENE_ID = l.BENE_ID
  WHERE l.fill_dt >= DATE '2016-03-01'
    AND (l.prev IS NULL OR l.fill_dt - l.prev > 365)
    AND l.fill_dt >= demo.birth + INTERVAL 65 YEAR
    AND EXISTS (SELECT 1 FROM enroll_span s WHERE s.BENE_ID = l.BENE_ID
                AND s.span_start <= date_trunc('month', l.fill_dt - INTERVAL 365 DAY) AND s.span_end >= l.fill_dt))
SELECT BENE_ID, atc_id, min(fill_dt) AS idx FROM e GROUP BY 1, 2;

-- condition present at the new-use date = at least one claim with a CCW code for the condition in the 365 days up to and including the index (amendment A-003 rule)
CREATE OR REPLACE TABLE nu_cond AS
SELECT DISTINCT n.BENE_ID, n.atc_id, n.idx, c.cond
FROM nu n JOIN dx_cond c ON c.BENE_ID = n.BENE_ID AND c.dt BETWEEN n.idx - 365 AND n.idx;

CREATE OR REPLACE TABLE cond_class AS
SELECT cond, atc_id, count(*) AS n_new_users FROM nu_cond GROUP BY 1, 2 HAVING count(*) >= 200;

-- active-comparator pairs: two classes in the same ATC level-2 group (first 3 characters), both with >= 200 new users in the condition.
-- Arm A = new users of A with no fill of B in the prior 365 days; arm B likewise (so arms are mutually exclusive at baseline).
CREATE OR REPLACE TABLE pair_arms AS
WITH p AS (
  SELECT a.cond, a.atc_id AS a_cls, b.atc_id AS b_cls FROM cond_class a JOIN cond_class b
  ON a.cond = b.cond AND a.atc_id < b.atc_id AND left(a.atc_id, 3) = left(b.atc_id, 3)),
arm_a AS (
  SELECT p.cond, p.a_cls, p.b_cls, count(*) AS n_a,
    count(*) FILTER (WHERE EXISTS (SELECT 1 FROM fill_class g WHERE g.BENE_ID = u.BENE_ID AND g.atc_id = p.b_cls AND g.fill_dt BETWEEN u.idx AND u.idx + 30)) AS n_a_with_b
  FROM p JOIN nu_cond u ON u.cond = p.cond AND u.atc_id = p.a_cls
  WHERE NOT EXISTS (SELECT 1 FROM fill_class f WHERE f.BENE_ID = u.BENE_ID AND f.atc_id = p.b_cls AND f.fill_dt BETWEEN u.idx - 365 AND u.idx - 1)
  GROUP BY ALL),
arm_b AS (
  SELECT p.cond, p.a_cls, p.b_cls, count(*) AS n_b,
    count(*) FILTER (WHERE EXISTS (SELECT 1 FROM fill_class g WHERE g.BENE_ID = u.BENE_ID AND g.atc_id = p.a_cls AND g.fill_dt BETWEEN u.idx AND u.idx + 30)) AS n_b_with_a
  FROM p JOIN nu_cond u ON u.cond = p.cond AND u.atc_id = p.b_cls
  WHERE NOT EXISTS (SELECT 1 FROM fill_class f WHERE f.BENE_ID = u.BENE_ID AND f.atc_id = p.a_cls AND f.fill_dt BETWEEN u.idx - 365 AND u.idx - 1)
  GROUP BY ALL)
SELECT arm_a.cond, arm_a.a_cls, arm_a.b_cls, n_a, n_b, n_a_with_b, n_b_with_a, least(n_a, n_b) AS min_arm
FROM arm_a JOIN arm_b USING (cond, a_cls, b_cls);
