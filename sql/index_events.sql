-- Hypertension cohort (protocol v0.3, Section 5): index candidates and per-criterion flags.
-- Inputs: rx_fill, demo, dx_long, ip_stay, hospice_clm, enroll_span (canonical.sql / step 04) and registered code-list tables
--   ndc_ahtn(ndc11, ahtn_class)   ahtn_class in ACEI, THIAZIDE, ARB, CCB, BB, LOOP, OTHER_DIURETIC, OTHER_ANTIHTN (a combination NDC has one row per class)
--   ndc_resolved(ndc11)           NDCs with an RxNorm record (measure 1; all others have "no RxNorm record")
--   icd_htn(code)                 I10-I16 codes (no decimal point, as in the claims)
-- Study-drug fills on or after 2016-03-01 so that a full 365-day baseline exists. Parameter placeholders: none (dates are fixed by the protocol).

CREATE OR REPLACE TABLE ahtn_fill AS
SELECT f.BENE_ID, f.fill_dt, f.days_supply, n.ahtn_class
FROM rx_fill f JOIN ndc_ahtn n ON n.ndc11 = f.ndc11;

-- one candidate per beneficiary and fill date; combination products give acei = thiazide = TRUE
CREATE OR REPLACE TABLE study_day AS
SELECT BENE_ID, fill_dt AS idx, bool_or(ahtn_class = 'ACEI') AS acei, bool_or(ahtn_class = 'THIAZIDE') AS thiazide
FROM ahtn_fill WHERE ahtn_class IN ('ACEI', 'THIAZIDE') AND fill_dt >= DATE '2016-03-01'
GROUP BY BENE_ID, fill_dt;

-- criterion 1: new user (no fill of any antihypertensive class in days -365 to -1). Later criteria are evaluated on these candidates only.
CREATE OR REPLACE TABLE cand_nu AS
SELECT s.* FROM study_day s
WHERE NOT EXISTS (SELECT 1 FROM ahtn_fill a WHERE a.BENE_ID = s.BENE_ID AND a.fill_dt BETWEEN s.idx - 365 AND s.idx - 1);

CREATE OR REPLACE TABLE cand_flags AS
SELECT c.BENE_ID, c.idx, c.acei, c.thiazide,
  c.idx >= d.birth + INTERVAL 65 YEAR AS f_age,
  EXISTS (SELECT 1 FROM enroll_span e WHERE e.BENE_ID = c.BENE_ID
          AND e.span_start <= date_trunc('month', c.idx - INTERVAL 365 DAY) AND e.span_end >= c.idx) AS f_enroll,
  -- A-009: eligibility accepts a hypertension diagnosis from day -365 through the index date; the strict version (days -365 to -1) is a sensitivity analysis
  EXISTS (SELECT 1 FROM dx_long x JOIN icd_htn h ON h.code = x.code
          WHERE x.BENE_ID = c.BENE_ID AND x.dt BETWEEN c.idx - 365 AND c.idx) AS f_htn,
  EXISTS (SELECT 1 FROM dx_long x JOIN icd_htn h ON h.code = x.code
          WHERE x.BENE_ID = c.BENE_ID AND x.dt BETWEEN c.idx - 365 AND c.idx - 1) AS f_htn_strict,
  NOT (c.acei AND c.thiazide) AS f_notboth,
  -- A-010: another antihypertensive class (not a study class) filled on the index date; a combination product containing another class counts
  NOT EXISTS (SELECT 1 FROM ahtn_fill a WHERE a.BENE_ID = c.BENE_ID AND a.fill_dt = c.idx AND a.ahtn_class NOT IN ('ACEI', 'THIAZIDE')) AS f_nocostart,
  NOT EXISTS (SELECT 1 FROM hospice_clm h WHERE h.BENE_ID = c.BENE_ID AND h.from_dt <= c.idx - 1 AND h.thru_dt >= c.idx - 365) AS f_nohospice,
  NOT EXISTS (SELECT 1 FROM ip_stay s WHERE s.BENE_ID = c.BENE_ID AND s.adm_dt <= c.idx AND s.thru_dt >= c.idx) AS f_noinpt,
  -- informational / sensitivity flags (not criteria in the primary cohort)
  EXISTS (SELECT 1 FROM rx_fill r WHERE r.BENE_ID = c.BENE_ID AND r.fill_dt BETWEEN c.idx - 365 AND c.idx - 1
          AND r.ndc11 NOT IN (SELECT ndc11 FROM ndc_resolved)) AS info_no_rxnorm_baseline_fill
FROM cand_nu c JOIN demo d ON d.BENE_ID = c.BENE_ID;
