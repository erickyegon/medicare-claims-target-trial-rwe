-- Follow-up windows and first outcome dates for a hypertension cohort table (protocol v0.4 Sections 7 and 9). No models.
-- Placeholders replaced by R: @COHORT@ (cohort table with BENE_ID, idx, arm, costart, no_rxnorm_baseline) and @DATA_END@ (end of data, 2023-03-31).
-- Inputs: enroll_ab_span, enroll_span, ip_stay, dx_long, icd_fx(code).
-- ab_end  = end of the continuous Part A+B span containing the index month; abd_end = end of the continuous Part A+B+D span.
-- first_adm / first_fx = first inpatient admission / first femur-fracture diagnosis on days 1-365 (absolute); R compares them with each follow-up end.
CREATE OR REPLACE TABLE fu_base AS
SELECT h.BENE_ID, h.idx, h.arm, h.costart, h.no_rxnorm_baseline,
  (SELECT max(s.span_end) FROM enroll_ab_span s WHERE s.BENE_ID = h.BENE_ID AND s.span_start <= h.idx AND s.span_end >= h.idx) AS ab_end,
  (SELECT max(s.span_end) FROM enroll_span s WHERE s.BENE_ID = h.BENE_ID AND s.span_start <= h.idx AND s.span_end >= h.idx) AS abd_end
FROM @COHORT@ h;

CREATE OR REPLACE TABLE fu_outcomes AS
SELECT f.*,
  (SELECT min(s.adm_dt) FROM ip_stay s WHERE s.BENE_ID = f.BENE_ID AND s.adm_dt BETWEEN f.idx + 1 AND f.idx + 365) AS first_adm,
  (SELECT min(x.dt) FROM dx_long x JOIN icd_fx c ON c.code = x.code WHERE x.BENE_ID = f.BENE_ID AND x.dt BETWEEN f.idx + 1 AND f.idx + 365) AS first_fx
FROM fu_base f;
