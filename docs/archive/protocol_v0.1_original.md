# Antiviral RWE Claims Project: Outline & Protocol

Oct 20, 2026 · @Erick kiprotich YEGON

## Part A: Updated project outline

A focused 3-week build that demonstrates US Medicare claims programming end to end: from raw files to cohort, analytic dataset, analysis and TFLs. Because the data are synthetic, it is framed as a methods and programming demonstration, not as evidence about antiviral effectiveness.

### What changed from the first plan

- **Data source:** use the newer CMS Synthetic Medicare Enrollment, FFS Claims and PDE files (ICD-10, RIF-style variable names, 8,671 beneficiaries) instead of the 2008–2010 DE-SynPUF (ICD-9).
- **Scope:** one clinical question (outpatient influenza, oseltamivir vs no antiviral) instead of a broad viral respiratory illness study.
- **Design:** time zero handled explicitly with a 2-day grace period and clone–censor–weight, so immortal-time bias is addressed by design.
- **Feasibility is a deliverable:** with \~8,700 beneficiaries the cohort may be very small; a documented feasibility assessment is the expected result, not a failure.
- **Dual programming:** core cohort steps written in R and independently re-derived in SAS (SAS OnDemand) as QC.
- **Timeline:** 3 weeks, built in parallel with applications rather than before them.

### Study question

Among Medicare beneficiaries aged 65+ with an outpatient influenza diagnosis, does oseltamivir dispensed within 2 days of diagnosis, compared with no antiviral, change the 30-day risk of hospitalization and death?

### 3-week plan

| Week | Focus | Deliverables |
| --- | --- | --- |
| 1 | Protocol, code lists, data ingestion | Protocol v1.0, code lists (ICD-10, NDC, HCPCS/CPT), DuckDB database, data profiling report |
| 2 | Cleaning, enrollment logic, cohort, feasibility | Enrollment spans, attrition table, feasibility report, analytic dataset v1, SAS re-derivation of cohort counts |
| 3 | Analysis, TFLs, report, packaging | SAP v1.0, baseline table, PS balance, KM and risk estimates, sensitivity analyses, TFL set, study report, README |

### Optional extensions (after applying)

- Add an active comparator (baloxavir) if counts allow.
- Map the cohort to OMOP CDM to link with the NSCLC project.
- Repeat the cohort logic on MIMIC-IV for an EHR-side comparison once PhysioNet access is in place.

### Tech stack

- R: tidyverse, data.table, survival, WeightIt, cobalt, gtsummary, targets, renv
- SQL on DuckDB for ingestion, joins and enrollment-span logic
- SAS (OnDemand): cohort and baseline table re-derivation with macros
- Quarto for the protocol, SAP and study report; GitHub Actions for CI

### Repository structure

```
antiviral-medicare-rwe/
  docs/          protocol.qmd, sap.qmd, study_report.qmd
  codelists/     icd10_influenza.csv, ndc_antivirals.csv, comorbidities.csv
  R/             01_ingest.R ... 07_tfl.R (targets pipeline)
  sas/           cohort_qc.sas, macros/
  sql/           enrollment_spans.sql, index_events.sql
  qc/            reconciliation logs, R vs SAS count checks
  output/tfl/    tables, figures, listings
```

### How it maps to the IQVIA posting

| Posting asks for | Where the project shows it |
| --- | --- |
| Raw data processing, checks, cleaning of claims | Ingestion, profiling report, cleaning functions, QC logs |
| Feasibility, cohort building, variable definition and validation | Code lists, attrition table, feasibility report, variable logic checks |
| Censoring, confounding, person-time, missing data | Enrollment-based censoring, IPTW + IPCW, person-time datasets |
| Survival, longitudinal, regression, PS methods | KM, weighted Cox and pooled logistic models, balance diagnostics |
| TFLs for protocols and reports | TFL shell list and generated outputs |
| Protocols, SAPs, study reports | Protocol, SAP and study report in docs/ |
| SAS and/or R, macros, SQL | R pipeline, SAS macros for QC, DuckDB SQL |

### How to describe it

"I built an end-to-end RWE study on CMS synthetic Medicare claims: code lists, enrollment logic, cohort and feasibility, PS-weighted survival analysis with a target-trial design, and full TFLs. The data are synthetic, so the results aren't inferential, but the programming and methods are the same as on real claims."

## Part B: Study protocol (draft v0.1)

**Title:** Early oseltamivir versus no antiviral and 30-day outcomes in older adults with outpatient influenza: a target trial emulation using CMS synthetic Medicare claims

**Investigator and programmer:** Erick Yegon

**Status:** Methods demonstration. CMS synthetic data do not support inference about real beneficiaries; all estimates are illustrative.

### 1. Background and rationale

Adults aged 65 and older carry most influenza-related hospitalizations and deaths. Guidelines recommend early antiviral treatment for high-risk outpatients, yet real-world uptake is incomplete and observational estimates are vulnerable to confounding by indication and immortal-time bias. This study specifies a target trial and emulates it in a claims structure, showing how those biases are handled through design and analysis.

### 2. Objectives

**Primary:** Estimate the 30-day risk of all-cause hospitalization for oseltamivir dispensed within 2 days of an outpatient influenza diagnosis, compared with no antiviral.

**Secondary:**

1. 30-day all-cause mortality.
2. 30-day composite of hospitalization or death.
3. 30-day outpatient and emergency department visit counts.
4. Treatment patterns: proportion treated, days from diagnosis to dispensing, and variation by age group, sex, dual eligibility and season.

**Feasibility:** Document cohort size, attrition and event counts in the synthetic files, and state which objectives are estimable.

### 3. Target trial specification and emulation

| Component | Target trial | Emulation in claims |
| --- | --- | --- |
| Eligibility | Age 65+, outpatient influenza, no recent antiviral, not hospitalized | Same, defined from enrollment, carrier/outpatient and PDE files (Section 5) |
| Treatment strategies | (1) Start oseltamivir within 2 days; (2) no antiviral within 30 days | Part D dispensing of oseltamivir within days 0–2 vs none |
| Assignment | Randomized at diagnosis | Clone–censor–weight with IPTW for baseline confounding |
| Time zero | Date of diagnosis | Index date = first qualifying outpatient influenza claim |
| Follow-up | 30 days | Index to earliest of outcome, death, disenrollment, end of data, day 30 |
| Outcomes | Hospitalization, death | Inpatient admission date; date of death in enrollment file |
| Causal contrast | Per-protocol effect | Per-protocol effect via artificial censoring and IPCW |
| Analysis | Risk difference and risk ratio at day 30 | Weighted Kaplan–Meier and pooled logistic models |

### 4. Data source

CMS Synthetic Medicare Enrollment, Fee-for-Service Claims and Prescription Drug Event files, which follow the structure of the CMS research identifiable files. Files used: beneficiary enrollment summary, inpatient, outpatient, carrier, and Part D event files.

- Data years and variable availability will be confirmed against the CMS user guide before code lists are finalized.
- Data are loaded into DuckDB; no record-level data are published in the repository.

### 5. Study population

**Index event:** first outpatient influenza diagnosis (ICD-10-CM J09.X–, J10.–, J11.–) in any position on a carrier or outpatient claim during an influenza season (October 1 to May 31).

**Inclusion criteria:**

1. Age 65 or older on the index date.
2. Continuous Part A, Part B and Part D enrollment for 365 days before index (baseline period).
3. No Medicare Advantage (Part C) enrollment during baseline, so claims are complete.

**Exclusion criteria:**

1. Inpatient admission on the index date or the day before (not an outpatient case).
2. Any influenza diagnosis or influenza antiviral dispensing in the 180 days before index (washout).
3. Hospice enrollment or end-stage renal disease during baseline.
4. Death recorded on or before the index date (data errors).

The first qualifying episode per beneficiary is used.

### 6. Exposure

**Treated strategy:** oseltamivir dispensed via Part D on days 0–2 after index (grace period), identified from NDCs mapped from the FDA NDC Directory by generic name.

**Untreated strategy:** no influenza antiviral (oseltamivir, baloxavir, zanamivir, peramivir) dispensed or administered during follow-up.

Peramivir is identified from carrier and outpatient HCPCS codes. Any non-oseltamivir antiviral in days 0–2 leads to exclusion from the primary analysis.

### 7. Outcomes

| Outcome | Definition | Source |
| --- | --- | --- |
| All-cause hospitalization (primary) | First inpatient admission on days 1–30 | Inpatient file, admission date |
| All-cause mortality | Death on days 1–30 | Enrollment file, date of death |
| Hospitalization or death | Earliest of the two | Both |
| Outpatient and ED visits | Count of distinct visit dates on days 1–30; ED via revenue center codes where available | Outpatient and carrier files |
| ICU admission (exploratory) | ICU revenue center codes during a qualifying admission | Inpatient revenue lines, if present |

**Negative control outcome:** hip or femur fracture on days 1–30, which oseltamivir should not affect. Its association flags residual confounding.

### 8. Covariates

Measured in the 365-day baseline unless noted.

- Demographics at index: age group, sex, race/ethnicity (RTI race code), dual Medicaid eligibility, state, index month and season.
- Comorbidity: Charlson components and score (ICD-10 algorithm), plus individual high-risk conditions (COPD, asthma, heart failure, diabetes, chronic kidney disease, immunosuppression).
- Health care use: number of outpatient visits, any hospitalization, any ED visit, number of distinct Part D drugs.
- Influenza vaccination in the current season (vaccine CPT/HCPCS codes, including administration code G0008).
- Index visit setting: physician office vs hospital outpatient vs ED.

**Missing data:** in claims, the absence of a code means the condition is treated as absent. Missing demographics get an explicit "unknown" category. Missingness is reported for every variable.

### 9. Follow-up and censoring

Follow-up starts at index (day 0) and ends at the earliest of: outcome, death, loss of Part A/B/D enrollment or start of Part C, end of data, or day 30.

For the per-protocol analysis, each eligible beneficiary is cloned into both strategies at day 0:

- The **treated clone** is censored at day 2 if oseltamivir has not been dispensed.
- The **untreated clone** is censored on the day any antiviral is dispensed.
- Outcomes during days 0–2 before any deviation count toward both clones, which removes immortal time.

### 10. Statistical analysis

1. **Feasibility and description.** Attrition table; baseline characteristics by observed treatment within the grace period; treatment patterns (proportion treated, distribution of days to dispensing).
2. **Baseline confounding.** Propensity score for treatment within the grace period estimated by logistic regression on all Section 8 covariates. Stabilized inverse probability of treatment weights, truncated at the 1st and 99th percentiles. Balance checked with standardized mean differences (target below 0.1) and a love plot.
3. **Artificial censoring.** Inverse probability of censoring weights estimated from baseline covariates for deviation during the grace period, combined with IPTW.
4. **Effect estimation.** Weighted Kaplan–Meier curves and weighted pooled logistic regression on person-days. Report 30-day risks per arm, risk difference and risk ratio. 95% confidence intervals by nonparametric bootstrap (500 resamples, resampling individuals, not clones).
5. **Secondary.** Same approach for mortality and the composite. Visit counts modeled with weighted negative binomial regression.
6. **Small-cell rule.** Results based on fewer than 11 events are flagged, following CMS cell-size convention, even though data are synthetic.

### 11. Sensitivity analyses

- Grace period of 1 day and 3 days.
- Landmark analysis starting at day 2, comparing those treated vs untreated by then.
- Exclude outcomes on days 0–2.
- Propensity score matching (1:1, caliper 0.2 SD of the logit) instead of weighting.
- Untruncated weights.
- Restrict to beneficiaries with influenza as the first-listed diagnosis.
- Negative control outcome (Section 7).
- E-value for the primary estimate.

### 12. Quality control

- Data profiling of every source file: row counts, date ranges, duplicate claims, invalid codes, impossible dates.
- Code lists versioned in the repository with source and date of each list.
- Independent re-derivation of the attrition table and baseline table in SAS; counts must match R exactly.
- Unit tests on enrollment-span logic and clone–censor logic using hand-built test beneficiaries.
- Log review for warnings, notes and dropped records at each pipeline step.
- Every TFL traced to the program and dataset version that produced it.

### 13. Limitations

- Synthetic data: associations between variables may not reflect real clinical relationships, so estimates are not interpretable as treatment effects.
- Small sample (about 8,700 beneficiaries): the cohort and event counts may be too small for stable estimates.
- Claims-based influenza diagnosis without laboratory confirmation leads to outcome-independent misclassification.
- Antivirals obtained outside Part D (samples, cash pay) are not captured.
- Unmeasured severity at presentation remains a source of confounding by indication.

### 14. Planned tables, figures and listings

| ID | Title |
| --- | --- |
| T1 | Cohort attrition |
| T2 | Baseline characteristics by treatment, before and after weighting, with SMDs |
| T3 | Treatment patterns and time to dispensing |
| T4 | 30-day risks, risk difference and risk ratio, primary and secondary outcomes |
| T5 | Sensitivity analyses |
| T6 | Negative control outcome |
| F1 | Study design diagram (index, washout, grace period, follow-up) |
| F2 | Love plot of covariate balance |
| F3 | Propensity score distributions by treatment |
| F4 | Weighted cumulative incidence curves for hospitalization |
| L1 | Code lists (ICD-10, NDC, HCPCS/CPT) |
| L2 | Variable derivation listing |

### 15. Open questions

- [ ] Confirm data years in the synthetic files and whether they span at least one full influenza season with baseline.
- [ ] Confirm whether the PDE file carries usable NDCs for oseltamivir.
- [ ] Confirm whether revenue center lines are available for ED and ICU definitions.
- [ ] Decide whether to add baloxavir as an active comparator after feasibility counts.
