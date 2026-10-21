-- Indication scan, step 4: trace the antibiotics that exist in PDE (amoxicillin-clavulanate, moxifloxacin).
-- A fill belongs to a drug if RxNorm resolves its NDC to exactly that ingredient set. No age or enrollment restriction here.
CREATE OR REPLACE TABLE trace_fills AS
SELECT DISTINCT BENE_ID, fill_dt, ndc11, drug_name FROM fill_drug WHERE drug_name IN ('amoxicillin / clavulanate', 'moxifloxacin');

-- diagnoses on any claim (carrier, outpatient, inpatient) dated in the 7 days up to and including the fill date
CREATE OR REPLACE TABLE trace_dx AS
SELECT t.drug_name, t.BENE_ID, t.fill_dt, t.ndc11, d.dx3, d.code
FROM trace_fills t JOIN dx_long d ON d.BENE_ID = t.BENE_ID AND d.dt BETWEEN t.fill_dt - 7 AND t.fill_dt;
