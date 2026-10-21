-- Indication scan, step 1: shared lookup tables (aggregate-only outputs are produced in later steps).
-- Registered by R before this runs: ndc_rxcui(ndc11, rxcui), rx_drug(rxcui, drug_name, ...), rx_atc(rxcui, atc_id, atc_name, ...), ccw_all(ccw_condition, icd10_code)

CREATE OR REPLACE TABLE demo AS SELECT BENE_ID, min(BENE_BIRTH_DT) AS birth FROM bene GROUP BY 1;

-- one row per beneficiary / claim / diagnosis code (claim files are line-level, so DISTINCT)
CREATE OR REPLACE TABLE dx_long AS
SELECT DISTINCT BENE_ID, CLM_ID, dt, src, code, left(code, 3) AS dx3 FROM (
  SELECT BENE_ID, CLM_ID, CLM_FROM_DT AS dt, 'carrier' AS src, unnest([PRNCPAL_DGNS_CD, ICD_DGNS_CD1, ICD_DGNS_CD2, ICD_DGNS_CD3, ICD_DGNS_CD4, ICD_DGNS_CD5, ICD_DGNS_CD6, ICD_DGNS_CD7, ICD_DGNS_CD8, ICD_DGNS_CD9, ICD_DGNS_CD10, ICD_DGNS_CD11, ICD_DGNS_CD12]) AS code FROM carrier
  UNION ALL
  SELECT BENE_ID, CLM_ID, CLM_FROM_DT, 'outpatient', unnest([PRNCPAL_DGNS_CD, ICD_DGNS_CD1, ICD_DGNS_CD2, ICD_DGNS_CD3, ICD_DGNS_CD4, ICD_DGNS_CD5, ICD_DGNS_CD6, ICD_DGNS_CD7, ICD_DGNS_CD8, ICD_DGNS_CD9, ICD_DGNS_CD10, ICD_DGNS_CD11, ICD_DGNS_CD12, ICD_DGNS_CD13, ICD_DGNS_CD14, ICD_DGNS_CD15, ICD_DGNS_CD16, ICD_DGNS_CD17, ICD_DGNS_CD18, ICD_DGNS_CD19, ICD_DGNS_CD20, ICD_DGNS_CD21, ICD_DGNS_CD22, ICD_DGNS_CD23, ICD_DGNS_CD24, ICD_DGNS_CD25]) FROM outpatient
  UNION ALL
  SELECT BENE_ID, CLM_ID, CLM_FROM_DT, 'inpatient', unnest([PRNCPAL_DGNS_CD, ICD_DGNS_CD1, ICD_DGNS_CD2, ICD_DGNS_CD3, ICD_DGNS_CD4, ICD_DGNS_CD5, ICD_DGNS_CD6, ICD_DGNS_CD7, ICD_DGNS_CD8, ICD_DGNS_CD9, ICD_DGNS_CD10, ICD_DGNS_CD11, ICD_DGNS_CD12, ICD_DGNS_CD13, ICD_DGNS_CD14, ICD_DGNS_CD15, ICD_DGNS_CD16, ICD_DGNS_CD17, ICD_DGNS_CD18, ICD_DGNS_CD19, ICD_DGNS_CD20, ICD_DGNS_CD21, ICD_DGNS_CD22, ICD_DGNS_CD23, ICD_DGNS_CD24, ICD_DGNS_CD25]) FROM inpatient)
WHERE code IS NOT NULL AND code <> '';

CREATE OR REPLACE TABLE adm AS SELECT DISTINCT BENE_ID, CLM_ADMSN_DT AS adm_dt FROM inpatient WHERE CLM_ADMSN_DT IS NOT NULL;

CREATE OR REPLACE TABLE fill AS SELECT DISTINCT BENE_ID, SRVC_DT AS fill_dt, PROD_SRVC_ID AS ndc11 FROM pde;

-- has_drug_concept = RxNorm resolved the NDC to at least one drug (ingredient set)
CREATE OR REPLACE TABLE fill_drug AS
SELECT DISTINCT f.BENE_ID, f.fill_dt, f.ndc11, d.drug_name
FROM fill f JOIN ndc_rxcui n ON n.ndc11 = f.ndc11 JOIN rx_drug d ON d.rxcui = n.rxcui;

CREATE OR REPLACE TABLE fill_drug_flag AS
SELECT f.BENE_ID, f.fill_dt, f.ndc11, f.ndc11 IN (SELECT ndc11 FROM fill_drug) AS has_drug_concept FROM fill f;

CREATE OR REPLACE TABLE fill_class AS
SELECT DISTINCT f.BENE_ID, f.fill_dt, a.atc_id, a.atc_name
FROM fill f JOIN ndc_rxcui n ON n.ndc11 = f.ndc11 JOIN rx_atc a ON a.rxcui = n.rxcui
WHERE length(a.atc_id) = 5;

CREATE OR REPLACE TABLE dx_cond AS
SELECT DISTINCT d.BENE_ID, c.ccw_condition AS cond, d.dt FROM dx_long d JOIN ccw_all c ON c.icd10_code = d.code;
