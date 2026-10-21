# Hypertension RWE Claims Project: Study Protocol (v0.3)

**Title:** ACE inhibitor versus thiazide or thiazide-like diuretic initiation and 365-day all-cause hospitalization in older adults with hypertension: an active-comparator new-user study using CMS synthetic Medicare claims

**Investigator and programmer:** Erick Yegon

**Status:** Methods demonstration. CMS states the synthetic files should not be used for scientific inference. All estimates are illustrative and are not treatment effects.

**Version history:**
- v0.1: influenza and oseltamivir (profiling found no influenza claims, no oseltamivir fills, no deaths).
- v0.2: acute bronchitis and antibiotics (archived in `docs/archive/protocol_v0.2_bronchitis.md`). Not estimable: amendment A-004.
- v0.3: hypertension, ACE inhibitor vs thiazide (amendment A-005, 2026-10-20). All amendments are in `docs/amendments.md`.

## 1. Background and rationale

ACE inhibitors and thiazide or thiazide-like diuretics are both first-line antihypertensive drugs. Observational comparisons of drug classes are vulnerable to prevalent-user bias, confounding by indication and immortal time. An active-comparator new-user design with time zero at the first fill addresses these by construction. This study specifies the design and emulates it in claims data, as a demonstration of cohort building, feasibility assessment, propensity score methods, censoring weights and reporting.

## 2. Objectives

**Primary:** Estimate the 365-day risk of all-cause hospitalization after initiating an ACE inhibitor compared with initiating a thiazide or thiazide-like diuretic (intention-to-treat).

**Secondary:**
1. As-treated 365-day hospitalization risk, censoring at add-on or switch to the other study drug or at discontinuation, with inverse probability of censoring weights.
2. 30-day all-cause hospitalization (intention-to-treat).

**Negative control outcome:** hip or femur fracture within 365 days.

**Feasibility:** Report cohort size, attrition, arm sizes, crude event counts and the time to add-on, switch and discontinuation per arm.

## 3. Design

| Component | Specification |
| --- | --- |
| Eligibility | Age 65+, new user of an antihypertensive, hypertension diagnosis in the baseline year, continuous Part A, B and D entitlement for 365 days |
| Strategies | (1) Initiate an ACE inhibitor; (2) initiate a thiazide or thiazide-like diuretic |
| Time zero | Date of the first fill of a study drug that meets all criteria (index date) |
| Assignment | Observed initiation; baseline confounding handled by propensity score weighting |
| Follow-up | 365 days |
| Outcomes | Hospitalization (inpatient admission date), negative control fracture |
| Causal contrasts | Intention-to-treat (primary); per-protocol approximated by as-treated censoring with IPCW (secondary) |

## 4. Data source

CMS Synthetic Medicare Enrollment, Fee-for-Service Claims and Prescription Drug Event files (RIF format, generated with Synthea). Files used: beneficiary 2015-2023, carrier, outpatient, inpatient, hospice and PDE. Files are pipe-delimited and linked on `BENE_ID`. Claims cover March 2015 to March 2023 (last claim date 2023-03-02). Data are loaded into DuckDB; no record-level data are published.

Facts that shape the design: no deaths; no influenza claims; ED visits are not identifiable (A-001); dual-eligibility months are fixed at 0; Part C is not modelled; Part D covers about 70% of person-months; PDE has NDCs only, and about 20% of fills cannot be identified through RxNorm (so exposure and washout use identifiable fills).

## 5. Study population

**Index event:** a fill of a study drug on or after 2016-03-01 (so a full baseline year exists). Fills on the same date are combined into one candidate. Candidates are evaluated in the order below; **one episode per beneficiary: the first that meets every criterion.**

**Criteria, applied in this order (attrition reported at each step):**
1. New user: no fill of any antihypertensive class in days -365 to -1.
2. Age 65 or older on the index date.
3. Continuous Part A, B and D entitlement from the month containing day -365 through the index month.
4. Hypertension diagnosis (ICD-10-CM I10-I16) on any inpatient, outpatient or carrier claim in days -365 to -1. (The number removed by this step is reported.)
5. Not both study drugs filled on the index date (a fixed-dose ACE inhibitor + thiazide product counts as both).
6. No hospice claim in days -365 to -1.
7. No inpatient stay overlapping the index date (admission date <= index date <= claim through-date).

**Study drugs** (oral; RxNorm ingredient lists from RxClass/ATC, `codelists/antihypertensive_ingredients.csv`): ACE inhibitors (ATC C09AA); thiazide and thiazide-like diuretics (ATC C03AA and C03BA).

**Antihypertensive washout classes:** the two study classes plus ARBs (C09CA), calcium channel blockers (C08), beta blockers (C07A), loop diuretics (C03C), other diuretics (C03D, C03E) and other antihypertensives (C02A, C02C, C02D, C09XA).

## 6. Exposure

Arm = class of the study drug filled on the index date (ACE inhibitor vs thiazide or thiazide-like). Fills are matched through PDE product service ID (NDC) to RxNorm ingredients (`codelists/ndc_antihypertensive.csv`). Fills whose NDC cannot be identified are counted for the new-user check only as an "unidentifiable baseline fill" sensitivity count.

## 7. Outcomes

| Outcome | Definition | Source |
| --- | --- | --- |
| Hospitalization (primary, 365 days; secondary, 30 days) | First inpatient admission on days 1 to 365 (1 to 30) | Inpatient file, admission date |
| Negative control | Hip or femur fracture (ICD-10-CM S72, initial encounter 7th character A, B, C) on any claim, days 1 to 365 | All claim files |

**Not estimable:** mortality (no deaths) and ED visits (no ED revenue centers, place of service or ED procedure codes; A-001).

## 8. Covariates

Measured in days -365 to -1 unless noted.

- Demographics at index: age, sex, race/ethnicity, state and region, index year and month.
- CCW chronic conditions (ICD-10 lists from the CCW algorithms; one qualifying claim in the baseline year, amendment A-003): COPD, asthma, heart failure, ischemic heart disease, diabetes, chronic kidney disease, dementia, cancer. Hypertension is constant by design.
- Health care use: outpatient visit days, any hospitalization, any ED-type visit if identifiable, number of distinct Part D drugs, **number of distinct drug classes** (ATC level 4, identifiable fills).
- Vaccination in the baseline year, if vaccine codes are present.

Dual eligibility is not used (fixed at 0). Index setting (carrier vs outpatient) is not used (A-002).

**Missing data:** absence of a code means the condition is absent. Missing demographics get an "unknown" category. Missingness is reported for every variable.

## 9. Follow-up and censoring

**Intention-to-treat:** follow-up starts the day after the index date and ends at the earliest of the outcome, day 365, the last claim date (2023-03-02) and loss of continuous Part A+B entitlement.

**As-treated (secondary):** additionally ends at the earliest of:
- the first fill of the other study drug (add-on if the index class is still covered by days supply, switch if not);
- discontinuation: the end of the index-class days supply (early refills carried forward) plus a 30-day grace period with no refill;
- loss of Part D entitlement.

Fills of other antihypertensive classes do not censor. Death is a censoring event for completeness (none expected).

## 10. Statistical analysis

Not run until Checkpoint 3 is confirmed.

1. **Feasibility and description.** Attrition table; arm sizes; baseline characteristics by arm; days supply; time to add-on, switch and discontinuation per arm.
2. **Baseline confounding.** Propensity score for ACE inhibitor vs thiazide initiation by logistic regression on the Section 8 covariates. Stabilized inverse probability of treatment weights truncated at the 1st and 99th percentiles. Balance by standardized mean differences (target < 0.1) and a love plot.
3. **Censoring.** Inverse probability of censoring weights (as-treated analysis) from baseline and time-updated information, combined with the treatment weights.
4. **Effect estimation.** Weighted Kaplan-Meier curves and weighted pooled logistic regression on person-days. 365-day and 30-day risks per arm, risk difference and risk ratio, with 95% confidence intervals from a nonparametric bootstrap (500 resamples of individuals).
5. **Negative control.** Same weighted analysis for hip or femur fracture.
6. **Small cells.** Results based on fewer than 11 events are flagged, following the CMS cell-size convention.

## 11. Sensitivity analyses (to be finalized in the SAP)

- Discontinuation grace period of 15 and 60 days.
- Propensity score matching (1:1, caliper 0.2 SD of the logit) instead of weighting; untruncated weights.
- Hypertension diagnosis allowed on the index date; stricter new-user rule excluding people with any unidentifiable baseline fill.
- Exclude people with chronic kidney disease.
- E-value for the primary estimate.

## 12. Feasibility findings to date

| Check | Result | Consequence |
| --- | --- | --- |
| Influenza claims (J09-J11); oseltamivir fills | 0; 0 | Influenza question not estimable (v0.1) |
| Deaths | 0 | Mortality not an outcome |
| ED visits | Not identifiable | A-001 |
| Bronchitis (J20) with listed antibiotics | No antibiotic fills 0-2 days after a first bronchitis claim | Not estimable (A-004, v0.2) |
| Indication scan | Generator models antibiotics for sinusitis and pharyngitis/tonsillitis; background antihypertensives, statins, NSAIDs and insulin appear in new users of every condition | Hypertension selected (A-005) |
| Candidate selection | Based on arm sizes and crude aggregate counts only; no effect estimates | Documented in A-005 |

Cohort size, attrition and event counts for this design are in `docs/feasibility.qmd` and `qc/`.

## 13. Quality control

- Profiling of every source file (`qc/profiling.html`); typing check on every converted column.
- Code lists versioned with source and date; ingredient lists regenerated by script.
- Unit tests on enrollment spans, index and exclusion logic, and the follow-up and censoring logic, using hand-built test beneficiaries.
- Independent SAS re-derivation of the attrition table; counts must match R exactly.
- Row counts logged in and out of every step (`qc/step_log.tsv`).
- Every TFL traced to the program and dataset version that produced it.

## 14. Limitations

- Synthetic data: drug-outcome relationships come from the generator's disease modules, not clinical biology, so estimates are not treatment effects. The generator gives the same background drug bundle to people with every condition.
- About 20% of PDE fills cannot be identified, so new-user status and exposure can be misclassified.
- NDC histories for a few products point to different drugs (0.7% of antihypertensive fills).
- Hospitalization cannot be broken down by cause here, and ED visits are not observable.
- Claims-based hypertension diagnosis without blood pressure values leaves confounding by indication and severity.
- Part D coverage is patchy, which reduces the cohort.

## 15. Planned tables, figures and listings

| ID | Title |
| --- | --- |
| T1 | Cohort attrition |
| T2 | Feasibility: influenza and bronchitis nulls, indication scan summary, hypertension cohort |
| T3 | Baseline characteristics by arm, before and after weighting, with SMDs |
| T4 | Treatment patterns: days supply, time to add-on, switch and discontinuation |
| T5 | 365-day and 30-day hospitalization risks, risk difference and risk ratio |
| T6 | Sensitivity analyses |
| T7 | Negative control outcome |
| F1 | Study design diagram (baseline, index, follow-up) |
| F2 | Love plot of covariate balance |
| F3 | Propensity score distributions by arm |
| F4 | Weighted cumulative incidence of hospitalization |
| L1 | Code lists (ICD-10, NDC, ingredient, revenue center) |
| L2 | Variable derivation listing |

## 16. Open questions

- [ ] Confirm the drafting interpretations 1-7 listed under A-005.
- [ ] How many new users does the hypertension diagnosis requirement remove?
- [ ] Are arm sizes and event counts adequate after all criteria?
- [ ] How many baseline fills are unidentifiable among candidates?
