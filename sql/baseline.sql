-- Baseline covariates for a hypertension cohort table (protocol v0.4 Section 8; covariate window days -365 to -1, amendment A-009).
-- Placeholder @COHORT@ is replaced by R. Inputs: the cohort table (BENE_ID, idx, arm, costart, no_rxnorm_baseline), demo, bene_year, dx_long, ip_stay, rx_fill,
-- and registered lookups ccw_codes(grp, code), ndc_drug(ndc11, drug_name), ndc_atc(ndc11, atc_id).
-- Chronic conditions use the A-003 rule: at least one claim with a CCW code in the baseline window. Index setting is not used (A-002).
-- Visit days = distinct dates of carrier or outpatient claims that carry a diagnosis. ED visits are not identifiable (A-001) and are not a covariate.
CREATE OR REPLACE TABLE bl_visit AS SELECT DISTINCT BENE_ID, dt FROM dx_long WHERE src IN ('carrier', 'outpatient');
CREATE OR REPLACE TABLE bl_dx_group AS SELECT DISTINCT d.BENE_ID, c.grp, d.dt FROM dx_long d JOIN ccw_codes c ON c.code = d.code;
CREATE OR REPLACE TABLE bl_fill_drug AS SELECT DISTINCT r.BENE_ID, r.fill_dt, n.drug_name FROM rx_fill r JOIN ndc_drug n ON n.ndc11 = r.ndc11;
CREATE OR REPLACE TABLE bl_fill_class AS SELECT DISTINCT r.BENE_ID, r.fill_dt, n.atc_id FROM rx_fill r JOIN ndc_atc n ON n.ndc11 = r.ndc11;

CREATE OR REPLACE TABLE htn_base AS
SELECT h.BENE_ID, h.arm, h.idx, h.costart, h.no_rxnorm_baseline,
  date_diff('year', d.birth, h.idx) - (CASE WHEN strftime(h.idx, '%m%d') < strftime(d.birth, '%m%d') THEN 1 ELSE 0 END) AS age,
  d.sex, year(h.idx) AS idx_year, quarter(h.idx) AS idx_quarter,
  coalesce(y.state, y0.state) AS state, coalesce(y.race, y0.race) AS race,
  (SELECT count(*) FROM bl_visit v WHERE v.BENE_ID = h.BENE_ID AND v.dt BETWEEN h.idx - 365 AND h.idx - 1) AS visit_days,
  (SELECT count(*) FROM ip_stay s WHERE s.BENE_ID = h.BENE_ID AND s.adm_dt BETWEEN h.idx - 365 AND h.idx - 1) AS n_admissions,
  (SELECT count(DISTINCT f.drug_name) FROM bl_fill_drug f WHERE f.BENE_ID = h.BENE_ID AND f.fill_dt BETWEEN h.idx - 365 AND h.idx - 1) AS n_drugs,
  (SELECT count(DISTINCT f.atc_id) FROM bl_fill_class f WHERE f.BENE_ID = h.BENE_ID AND f.fill_dt BETWEEN h.idx - 365 AND h.idx - 1) AS n_classes,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'copd' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS copd,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'asthma' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS asthma,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'heart_failure' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS heart_failure,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'ischemic_heart_disease' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS ischemic_heart_disease,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'diabetes' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS diabetes,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'chronic_kidney_disease' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS chronic_kidney_disease,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'dementia' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS dementia,
  EXISTS (SELECT 1 FROM bl_dx_group g WHERE g.BENE_ID = h.BENE_ID AND g.grp = 'cancer' AND g.dt BETWEEN h.idx - 365 AND h.idx - 1) AS cancer
FROM @COHORT@ h JOIN demo d ON d.BENE_ID = h.BENE_ID
LEFT JOIN bene_year y ON y.BENE_ID = h.BENE_ID AND y.yr = year(h.idx)
LEFT JOIN (SELECT BENE_ID, arg_min(state, yr) AS state, arg_min(race, yr) AS race FROM bene_year GROUP BY BENE_ID) y0 ON y0.BENE_ID = h.BENE_ID;
