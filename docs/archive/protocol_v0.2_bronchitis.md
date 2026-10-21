# Respiratory RWE Claims Project: Outline & Protocol

Oct 20, 2026 · @Erick kiprotich YEGON

## Part A: Updated project outline

The study is re-scoped to acute bronchitis and antibiotics, because profiling found zero influenza claims, zero oseltamivir fills and zero deaths in the CMS synthetic files. The target-trial design is unchanged; the influenza result is kept as a documented feasibility finding.

### What changed

- **Indication:** acute bronchitis (J20.9, about 300 beneficiaries a year over 9 years) replaces influenza.
- **Exposure:** any oral antibiotic dispensed on days 0–2 vs none, replacing oseltamivir vs none.
- **Outcomes:** hospitalization or ED visit within 30 days; mortality dropped because the synthetic population has no deaths.
- **Framing:** antibiotic treatment of a predominantly viral respiratory infection, an antimicrobial stewardship question that keeps the respiratory and virology angle.
- **Data facts built in:** claims run 2015 to March 2023; Part C is simulated but does not affect claims; dual-eligibility months are fixed at 0; about 70% of beneficiaries are in Part D in a given year.
- **Feasibility is a deliverable:** the influenza null and the bronchitis counts both go in the feasibility report.

### Study question

Among Medicare beneficiaries aged 65+ with an outpatient acute bronchitis diagnosis, does an oral antibiotic dispensed within 2 days, compared with no antibiotic, change the 30-day risk of hospitalization or an ED visit?

### 3-week plan

| Week | Focus | Deliverables |
| --- | --- | --- |
| 1 | Profiling (done), protocol v0.2, code lists | Profiling report, antibiotic NDC list (11-digit), ICD-10 and CCW code lists, revenue-center check for ED |
| 2 | Enrollment logic, cohort, feasibility | Enrollment spans, attrition table, feasibility report incl. influenza null, analytic dataset v1, SAS re-derivation of counts |
| 3 | Analysis, TFLs, report, packaging | SAP v1.0, baseline table, balance diagnostics, weighted risk curves, sensitivity analyses, TFL set, study report, README |

### Optional extensions

- Active comparator: amoxicillin vs azithromycin, if both arms have enough people.
- Map the cohort to OMOP CDM to connect with the NSCLC project.
- Repeat the cohort logic on MIMIC-IV once PhysioNet access is in place.

### Tech stack

- R: tidyverse, data.table, survival, WeightIt, cobalt, gtsummary, targets, renv
- SQL on DuckDB for ingestion, joins and enrollment spans (files are pipe-delimited)
- SAS (OnDemand): cohort and baseline table re-derivation with macros
- Quarto for protocol, SAP and report; GitHub Actions for CI

### Repository structure

```
bronchitis-abx-medicare-rwe/
  docs/          protocol.qmd, sap.qmd, feasibility.qmd, study_report.qmd
  codelists/     icd10_bronchitis.csv, icd10_exclusions.csv, ndc_antibiotics.csv, ccw_conditions.csv
  R/             01_ingest.R ... 08_tfl.R (targets pipeline)
  sas/           cohort_qc.sas, macros/
  sql/           enrollment_spans.sql, index_events.sql
  qc/            profiling, reconciliation logs, R vs SAS count checks
  output/tfl/    tables, figures, listings
```

### How it maps to the IQVIA posting

| Posting asks for | Where the project shows it |
| --- | --- |
| Raw data processing, checks, cleaning of claims | Ingestion, profiling report, cleaning functions, QC logs |
| Feasibility, cohort building, variable definition and validation | Influenza null, code lists, attrition table, feasibility report |
| Censoring, confounding, person-time, missing data | Enrollment-based censoring, IPTW + IPCW, person-time datasets |
| Survival, longitudinal, regression, PS methods | Weighted KM, pooled logistic and Cox models, balance diagnostics |
| TFLs for protocols and reports | TFL shell list and generated outputs |
| Protocols, SAPs, study reports | Protocol, SAP, feasibility and study report in docs/ |
| SAS and/or R, macros, SQL | R pipeline, SAS macros for QC, DuckDB SQL |

### How to describe it

"I built an end-to-end RWE study on CMS synthetic Medicare claims. My feasibility work showed the influenza question wasn't supported, so I re-scoped to antibiotics for acute bronchitis and ran a target-trial emulation with clone–censor–weight, PS weighting and full TFLs. The data are synthetic, so results aren't inferential, but the programming and methods are the same as on real claims."

## Part B: Study protocol (draft v0.2)

**Title:** Early antibiotic treatment versus no antibiotic and 30-day hospitalization or ED visits in older adults with acute bronchitis: a target trial emulation using CMS synthetic Medicare claims

**Investigator and programmer:** Erick Yegon

**Status:** Methods demonstration. CMS states the synthetic files should not be used for scientific inference; all estimates are illustrative.

**Version history:** v0.1 specified influenza and oseltamivir. v0.2 re-scopes to acute bronchitis after profiling found no influenza claims, oseltamivir fills or deaths (Section 12).

### 1. Background and rationale

Acute bronchitis in adults is predominantly viral, and guidelines advise against routine antibiotics. Antibiotics are still commonly prescribed, especially to older adults, partly from concern about progression to pneumonia or hospitalization. Observational comparisons are prone to confounding by indication and to immortal-time bias when treatment is defined in a window after diagnosis. This study specifies a target trial and emulates it in a claims structure, showing how both are handled.

### 2. Objectives

**Primary:** Estimate the 30-day risk of hospitalization or ED visit for an oral antibiotic dispensed within 2 days of an outpatient acute bronchitis diagnosis, compared with no antibiotic.

**Secondary:**

1. 30-day all-cause hospitalization alone.
2. 30-day pneumonia diagnosis (ICD-10-CM J12–J18) in any setting.
3. Count of outpatient and carrier visit days on days 1–30.
4. Treatment patterns: proportion treated, antibiotic class, days from diagnosis to dispensing, and variation by age group, sex, region and year.

**Feasibility:** Report cohort size, attrition and event counts, the influenza null, and which objectives are estimable.

### 3. Target trial specification and emulation

| Component | Target trial | Emulation in claims |
| --- | --- | --- |
| Eligibility | Age 65+, outpatient acute bronchitis, no recent antibiotic, no pneumonia or other bacterial infection | Same, from beneficiary, carrier, outpatient, inpatient and PDE files (Section 5) |
| Treatment strategies | (1) Start an oral antibiotic within 2 days; (2) no antibiotic within 30 days | Part D dispensing of an oral antibiotic on days 0–2 vs none |
| Assignment | Randomized at diagnosis | Clone–censor–weight with IPTW for baseline confounding |
| Time zero | Date of diagnosis | Index date = first qualifying outpatient bronchitis claim |
| Follow-up | 30 days | Index to earliest of outcome, disenrollment, end of data, day 30 |
| Outcomes | Hospitalization or ED visit | Inpatient admission date; ED revenue center lines on outpatient claims |
| Causal contrast | Per-protocol effect | Artificial censoring with IPCW |
| Analysis | Risk difference and risk ratio at day 30 | Weighted Kaplan–Meier and pooled logistic models |

### 4. Data source

CMS Synthetic Medicare Enrollment, Fee-for-Service Claims and Prescription Drug Event files (8,671 beneficiaries, RIF format, generated with Synthea). Files used: beneficiary\_2015 to beneficiary\_2023, carrier, outpatient, inpatient and pde. Files are pipe-delimited and linked on BENE\_ID.

- Claims cover March 2015 to March 2023.
- Data are loaded into DuckDB; no record-level data are published.
- Fields CMS fills with fixed or random values (Section 6 of the user guide) are listed in the data profiling report and not used as covariates.

### 5. Study population

**Index event:** first outpatient acute bronchitis diagnosis (ICD-10-CM J20.–; in practice J20.9) in any position on a carrier or outpatient claim, from March 2016 onward so a full baseline year is available.

**Inclusion criteria:**

1. Age 65 or older on the index date.
2. Continuous Part A, Part B and Part D entitlement for 365 days before index and on the index date (monthly indicators in the beneficiary files).

**Exclusion criteria:**

1. Inpatient admission on the index date or the day before.
2. Any oral antibiotic dispensed in the 30 days before index.
3. Pneumonia (J12–J18) diagnosed in the 30 days before index or on the index date.
4. Another antibiotic-indicating diagnosis on the index date: sinusitis (J01), pharyngitis or tonsillitis (J02, J03), otitis media (H65, H66), urinary tract infection (N39.0), skin infection (L03).
5. An acute bronchitis diagnosis in the 90 days before index (not a new episode).
6. Hospice claim in the baseline year.

One episode per beneficiary: the first that meets all criteria.

### 6. Exposure

**Treated strategy:** any systemic oral antibiotic dispensed via Part D on days 0–2 after index (grace period). Classes: penicillins (amoxicillin, amoxicillin–clavulanate), macrolides (azithromycin, clarithromycin), tetracyclines (doxycycline), cephalosporins (cephalexin, cefuroxime, cefdinir, cefpodoxime), fluoroquinolones (levofloxacin, moxifloxacin), and trimethoprim–sulfamethoxazole.

**Untreated strategy:** no systemic antibiotic dispensed during follow-up.

Antibiotic NDCs are built from the FDA NDC Directory (or openFDA / RxNorm) by generic name, normalized to 11 digits, and matched to the PDE product service ID. The list is versioned with its source and download date.

### 7. Outcomes

| Outcome | Definition | Source |
| --- | --- | --- |
| Hospitalization or ED visit (primary) | First inpatient admission or ED visit on days 1–30 | Inpatient admission date; outpatient revenue center codes 0450–0459, 0981 |
| All-cause hospitalization | First inpatient admission on days 1–30 | Inpatient file |
| Pneumonia | J12–J18 in any position on any claim, days 1–30 | All claim files |
| Visit days | Distinct outpatient or carrier service dates, days 1–30 | Outpatient, carrier |

If ED revenue center codes are not populated, the primary outcome becomes all-cause hospitalization and the change is recorded as a protocol amendment.

**Negative control outcome:** hip or femur fracture on days 1–30, which antibiotics should not affect.

**Not estimable:** mortality. The synthetic population contains only beneficiaries alive at the end of the simulation.

### 8. Covariates

Measured in the 365-day baseline unless noted.

- Demographics at index: age group, sex, race/ethnicity, state and region, index year and month.
- Chronic conditions using CCW definitions (grouping matters because the synthetic data use one code per condition): COPD, asthma, heart failure, ischemic heart disease, diabetes, chronic kidney disease, hypertension, dementia, cancer.
- Health care use: outpatient visit days, any hospitalization, any ED visit, number of distinct Part D drugs, any antibiotic 31–365 days before index.
- Influenza and pneumococcal vaccination in the baseline year, if vaccine codes are present.
- Index visit setting: carrier (office) vs outpatient facility claim.

Dual eligibility is excluded because it is fixed at 0 in the synthetic files.

**Missing data:** absence of a code means the condition is treated as absent. Missing demographics get an explicit "unknown" category. Missingness is reported for every variable.

### 9. Follow-up and censoring

Follow-up starts at index (day 0) and ends at the earliest of: outcome, loss of Part A, B or D entitlement, end of data, or day 30. Death is coded as a censoring event for completeness, although none is expected.

For the per-protocol analysis, each eligible beneficiary is cloned into both strategies at day 0:

- The **treated clone** is censored at day 2 if no antibiotic has been dispensed.
- The **untreated clone** is censored on the day any antibiotic is dispensed.
- Outcomes on days 0–2 before any deviation count toward both clones, which removes immortal time.

### 10. Statistical analysis

1. **Feasibility and description.** Attrition table; baseline characteristics by observed treatment in the grace period; treatment patterns by class and time to dispensing.
2. **Baseline confounding.** Propensity score for treatment in the grace period by logistic regression on all Section 8 covariates. Stabilized IPTW, truncated at the 1st and 99th percentiles. Balance by standardized mean differences (target below 0.1) and a love plot.
3. **Artificial censoring.** IPCW for deviation during the grace period, combined with IPTW.
4. **Effect estimation.** Weighted Kaplan–Meier curves and weighted pooled logistic regression on person-days. Report 30-day risks per arm, risk difference and risk ratio, with 95% confidence intervals from a nonparametric bootstrap (500 resamples of individuals, not clones).
5. **Secondary.** Same approach for hospitalization alone and pneumonia. Visit days by weighted negative binomial regression.
6. **Small cells.** Results based on fewer than 11 events are flagged, following CMS cell-size convention.

### 11. Sensitivity analyses

- Grace period of 1 day and 3 days.
- Landmark at day 2, comparing treated vs untreated by then.
- Active comparator: amoxicillin or amoxicillin–clavulanate vs azithromycin, if both arms are large enough.
- Exclude beneficiaries with COPD or asthma.
- Restrict to bronchitis as the first-listed diagnosis.
- Propensity score matching (1:1, caliper 0.2 SD of the logit) instead of weighting; untruncated weights.
- Negative control outcome; E-value for the primary estimate.

### 12. Feasibility findings to date

| Check | Result | Consequence |
| --- | --- | --- |
| Influenza claims (J09–J11) | 0 | Influenza question not estimable; reported as a null |
| Oseltamivir fills | 0 | As above |
| Deaths in the population | 0 | Mortality outcomes dropped |
| Acute bronchitis (J20.9) | About 300 beneficiaries a year, 9 years | Selected as new indication |
| Part C enrollment | Simulated, does not affect claims | Part C exclusion removed |
| Dual eligibility months | Fixed at 0 | Not used as covariate |

### 13. Quality control

- Profiling of every source file: row counts, date ranges, duplicate claims, invalid codes, impossible dates, fixed-value fields.
- Code lists versioned with source and date.
- Independent SAS re-derivation of the attrition and baseline tables; counts must match R exactly.
- Unit tests on enrollment spans and clone–censor logic using hand-built test beneficiaries.
- Log review for warnings and dropped records at each step.
- Every TFL traced to the program and dataset version that produced it.

### 14. Limitations

- Synthetic data: treatment–outcome relationships come from the generator's disease modules, not clinical biology, so estimates are not treatment effects.
- Small cohort and few events may give unstable estimates.
- Claims-based bronchitis diagnosis without clinical detail (symptoms, severity) leaves confounding by indication.
- Antibiotics obtained outside Part D are not captured.
- Synthetic coding is simpler than real claims, so code lists validated here need expansion on real data.

### 15. Planned tables, figures and listings

| ID | Title |
| --- | --- |
| T1 | Cohort attrition |
| T2 | Feasibility: influenza null and candidate indications |
| T3 | Baseline characteristics by treatment, before and after weighting, with SMDs |
| T4 | Treatment patterns by antibiotic class and time to dispensing |
| T5 | 30-day risks, risk difference and risk ratio, primary and secondary outcomes |
| T6 | Sensitivity analyses |
| T7 | Negative control outcome |
| F1 | Study design diagram (baseline, washout, grace period, follow-up) |
| F2 | Love plot of covariate balance |
| F3 | Propensity score distributions by treatment |
| F4 | Weighted cumulative incidence of the primary outcome |
| L1 | Code lists (ICD-10, NDC, revenue center) |
| L2 | Variable derivation listing |

### 16. Open questions

- [ ] Are ED revenue center codes (0450–0459, 0981) populated in the outpatient file?
- [ ] How many antibiotic NDCs match PDE product service IDs?
- [ ] Event counts for the primary outcome after cohort building.
- [ ] Are both active-comparator arms large enough?
