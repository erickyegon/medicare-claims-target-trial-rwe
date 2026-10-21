# SAS reconciliation (first run 2026-10-21)

`sas/cohort_qc.sas` re-derives the cohort attrition table and the baseline counts independently of the R code (month counting for enrollment, hash lookup for diagnoses, SQL joins for the other criteria) and compares them with `qc/cohort/attrition.csv` and `qc/cohort/cohort_baseline_counts.csv`.

**Result: attrition 11 of 11 rows PASS (episodes and persons); baseline 10 of 10 rows PASS (age group and sex by arm). No differences.** The final cohort is 790 people (ACE inhibitor 433, thiazide 357), as in R. Detail: `qc/cohort/sas_vs_r_attrition.csv`, `qc/cohort/sas_vs_r_baseline.csv`.

Run in SAS OnDemand for Academics (SAS Studio, one session): `download_raw.sas`, `inputs_codelists.sas`, `import_raw.sas`, `cohort_qc.sas`. Raw rows read: beneficiary 67,257 rows (9,179 people), carrier 1,121,004, outpatient 575,092, inpatient 58,066, Part D fills 515,520, hospice 12,107. The NDC map typed into the session matched the project list (3,539 rows; per-class counts and checksums equal).

## Defects found by the first run (all in the SAS programs; fixed before the passing run)
1. `inputs_codelists.sas`: `LRECL=` is not valid on an in-stream `INFILE DATALINES`.
2. `download_raw.sas`: `PROC HTTP OUT=` takes a fileref, not a quoted path.
3. `import_raw.sas`: filerefs are limited to 8 characters (`outpatient0`, `inpatient0` failed), and a multi-file `FILENAME` list takes quoted physical names only.
4. `cohort_qc.sas`: the first version used correlated subqueries per candidate; they did not finish in about 10 minutes and the session timed out. Rewritten as join-and-count steps (seconds).
None of these changed a result; the R counts were not adjusted to fit.

## Scope
This confirms the cohort-building logic (attrition and baseline counts) in a second language. It does not re-run follow-up, weighting or the outcome models. CI does not run SAS.
