# Protocol amendments and deviations

Every departure from `protocol.md` is recorded here before it is applied.

**Status legend:** PROPOSED (suggested, not yet decided) / APPROVED (the investigator agreed to the change) / APPLIED (already used in the code or analysis, usually to keep the study estimable) / CONFIRMED (the investigator reviewed and accepted an applied change) / REJECTED (declined). A line may carry several statuses with dates in the order they happened.

**Two named measures of PDE fills that cannot be linked to a drug** (also defined in the README): **no RxNorm record** = the NDC is not found in RxNorm at all (101,407 fills, 19.7% of PDE fills; 2,714 NDCs); **no RxNorm drug concept** = no RxNorm record, or a record that gives no drug (ingredient) concept (107,298 fills, 20.8%; the wider measure, which contains the first). The new-user sensitivity cohort uses the first; exposure, washout, drug counts and the indication scan use fills with a drug concept (the complement of the second).

## A-001: Primary outcome changes to all-cause hospitalization (no ED visits identifiable)

- **Date:** 2026-10-20 (Phase 1 profiling)
- **Protocol section:** 7 (Outcomes), 2 (Objectives), 3 (Target trial table), 15 (T5)
- **Trigger:** Section 7 states "If ED revenue center codes are not populated, the primary outcome becomes all-cause hospitalization and the change is recorded as a protocol amendment."
- **Evidence (`qc/profiling.qmd`, `R/02_profile.R::rev_center_check`):**
  - Outpatient file: 575,092 rows, `REV_CNTR` always populated, but only three distinct values (0001 on 574,480 rows; 0780 and 0789 on 612 rows). **0 rows** in 0450-0459 or 0981.
  - Other ED signals also absent: **0** carrier or outpatient rows with ED E/M HCPCS 99281-99285; carrier place-of-service 23 never occurs (observed: 11, 20, 22, 12, 31, 34, 02).
  - Inpatient `CLM_IP_ADMSN_TYPE_CD = 1` (emergency admission) exists, but that identifies admissions, not ED visits that did not lead to admission.
- **Change:** Primary outcome = first inpatient admission on days 1-30. The composite "hospitalization or ED visit" is not estimable and is reported as such in the feasibility report. Secondary objective 1 (hospitalization alone) is now the primary; the secondary list is renumbered (pneumonia, visit days, treatment patterns).
- **Status:** APPROVED 2026-10-20. Pneumonia and visit days remain secondary outcomes exactly as pre-specified. The primary outcome will not be changed later based on event counts; if events are sparse this is reported at Checkpoint 3.

## A-002: Drop "index visit setting (carrier vs outpatient facility)" as a covariate

- **Date:** 2026-10-20 (Phase 1 follow-up profiling)
- **Protocol section:** 8 (Covariates)
- **Evidence (`R/02b_profile_extra.R`, `qc/profile_op_*.csv`):**
  - Bronchitis (J20.x, any position) appears on 8,768 outpatient claims (2,494 beneficiaries) but only 1,015 carrier claims (657 beneficiaries).
  - Among each beneficiary's *first* bronchitis claim, **10 of 2,501 (0.4%)** are carrier claims. A covariate with ~10 people in one level cannot be estimated or balanced, and any cell below 11 is suppressed in the TFLs.
  - Carrier and outpatient bronchitis claims for the same beneficiary and day are essentially disjoint (1 beneficiary-day in both), so the file is not a proxy for a care pathway.
  - Outpatient claims carry no site-of-care detail: `CLM_SRVC_CLSFCTN_TYPE_CD` is 3 and `CLM_FAC_TYPE_CD` is 1 on every row, and 99.9% of lines have revenue code 0001 (a "total charges" line, not a department). The 612 lines with 0780/0789 are telemedicine-type revenue codes with HCPCS 99241, 99397, H2020 or CO. Carrier place of service is 11 (office) on 83% of lines.
- **Change:** Remove "index visit setting" from the covariate list; the propensity score model uses the remaining Section 8 covariates. Index events are still taken from either file.
- **Status:** APPROVED 2026-10-20.

## A-003: Ascertainment rule for CCW chronic-condition covariates

- **Date:** 2026-10-20 (Phase 2)
- **Protocol section:** 8 (Covariates)
- **Issue:** Protocol 8 says "chronic conditions using CCW definitions" but does not say how a person qualifies. The official CCW algorithms (`codelists/ccw_conditions.csv`, columns `ccw_lookback`, `ccw_claims_to_qualify`) require 1 inpatient/SNF/HHA claim or 2 hospital-outpatient/carrier claims within a 2-year look-back. The protocol baseline is 365 days.
- **Proposed rule:** a condition is present if the 365-day baseline contains **at least one** inpatient, outpatient or carrier claim with a code from the CCW list for that condition (any diagnosis position). Code lists are the official CCW ICD-10 lists; only the claim-count and look-back rules are simplified.
- **Why:** the synthetic data use one code per condition, so a 2-claim rule would under-ascertain, and only one baseline year is guaranteed.
- **Mapping:** dementia = CCW Alzheimer's disease + non-Alzheimer's dementia; cancer = CCW breast, colorectal, endometrial, lung, prostate and urologic cancers (CCW has no single "any cancer" algorithm in the 30-condition set); heart failure = CCW "Heart failure and non-ischemic heart disease".
- **Sensitivity/specificity note (user-requested):** one claim in a 365-day baseline is **more sensitive and less specific** than the CCW algorithm (which needs 1 inpatient/SNF/HHA claim or 2 outpatient/carrier claims in 2 years): it will classify more people as having the condition, including some with a single rule-out or erroneous code.
- **Status:** APPROVED 2026-10-20.

## A-004: Feasibility finding - bronchitis / antibiotic question is not estimable

- **Date:** 2026-10-20 (Phase 2, Checkpoint 2)
- **Protocol sections:** 1-3, 6, 10-11 (whole study question); 12 (feasibility findings)
- **Finding:** After building the antibiotic NDC list (18,015 eleven-digit NDCs, FDA directory + RxNorm historical NDCs), **no protocol-listed antibiotic is dispensed 0-2 days after a first bronchitis claim**. Crude count, before age and enrollment criteria: 2,373 people with a first J20.x claim since 2016-03; 0 with a listed-antibiotic fill on days 0-2; 10 within days 0-30. The treated arm is empty, so the primary comparison cannot be run. The crude count is in `qc/profiling_notes.md`; the Phase 3 attrition table will reproduce it on the final cohort.
- **Fills with and without an RxNorm record** (measure 1; RxNorm resolution of all 14,627 distinct PDE NDCs, `qc/profiling_notes.md`):

  | Scope | Has an RxNorm record | No RxNorm record |
  |---|---|---|
  | All PDE NDCs | 11,913 (81.4%) | 2,714 (18.6%) |
  | All PDE fills (515,520) | 414,113 (80.3%) | 101,407 (19.7%) |
  | Fills 0-2 days after first bronchitis claim (1,674) | 1,272 (76%) | 402 (24%) |

  The FDA directory alone identified only 14.1% of fills (72,693), because it lists current products and the data uses historical NDCs. Among fills with an RxNorm record, the drugs seen are mainly acetaminophen, opioids, insulin and tacrolimus; antibiotics are rare (1,672 listed-antibiotic fills in total, 0.3%). Antibiotic use inside the 24% of those fills with no RxNorm record cannot be excluded.
- **Change:** The bronchitis/antibiotic target-trial analysis (Phase 3 onward) is **not run**. The finding is reported as a feasibility result. Any re-scope will be recorded as a new amendment after the indication scan.
- **Status:** APPROVED 2026-10-20 (recorded on the user's instruction). Code lists and protocol text unchanged until a re-scope is chosen.

## A-005: Re-scope to hypertension, ACE inhibitor vs thiazide new-user design (protocol v0.3)

- **Date:** 2026-10-20
- **Protocol sections:** all (new study question); v0.2 archived in `docs/archive/protocol_v0.2_bronchitis.md`
- **Reason:** A-004 (bronchitis antibiotic question not estimable) and the indication scan (`qc/indication_scan.html`, `qc/scan/`).
- **How the candidate was selected:** from arm sizes and crude aggregate hospitalization counts in the scan only. **No effect estimates were computed or viewed.** The report keeps all three scan passes labelled as they are: *pre-specified* (smaller arm size; produced artifacts), *refined* (added after seeing the first pass) and *curated* (chosen by hand after reading sections 1-3). The hypertension pairs came from the curated pass.
- **New design:** active-comparator new-user cohort. Exposure: first fill of an ACE inhibitor vs a thiazide or thiazide-like diuretic (oral; RxNorm ingredient lists from RxClass ATC C09AA, and C03AA + C03BA). Index = first fill date.
- **New user:** no fill of any antihypertensive class (ACEI, ARB, thiazide, CCB, beta blocker, loop and other diuretics, other antihypertensives C02A/C02C/C02D/C09XA) in the 365 days before index. Only fills with an RxNorm drug concept can be assessed (measure 2); the number of people with a baseline fill that has no RxNorm record (measure 1) is reported.
- **Exclusions:** both study drugs filled on the index date (a fixed-dose ACEI+thiazide product counts as both); age < 65; < 365 days continuous Part A/B/D before index; hospice claim in the baseline year; inpatient stay overlapping the index date. **Required:** hypertension diagnosis (ICD-10-CM I10-I16) in the baseline year; the number of new users this removes is reported in the attrition table.
- **Primary outcome:** all-cause hospitalization within 365 days, intention-to-treat. **Secondary:** as-treated analysis (censor at add-on or switch to the other study drug, or discontinuation = 30-day gap after the days supply) with IPCW; 30-day hospitalization. **Negative control outcome:** hip/femur fracture (S72, initial encounter). Pneumonia, visit-day and treatment-pattern objectives from v0.2 no longer apply.
- **Covariates:** protocol Section 8 without index setting (A-002), plus baseline count of distinct drug classes; hypertension is constant by design and is not a covariate.
- **Interpretations made in drafting v0.3 (please confirm at Checkpoint 3):**
  1. Baseline window = days -365 to -1; the hypertension diagnosis and hospice criteria use it. The count of people who would additionally qualify with a diagnosis on the index date is reported as a sensitivity count.
  2. Inpatient overlap = admission date <= index date <= claim through-date.
  3. Intention-to-treat follow-up ends at the earliest of day 365, last claim date (2023-03-02) and loss of continuous Part A+B entitlement. Part D loss ends follow-up only in the as-treated analysis, because Part D coverage is patchy (about 70%) and does not affect observation of hospitalization.
  4. Discontinuation date = end of days supply (with carry-forward of early refills) + 30 days if no refill of the index class occurred in that grace period.
  5. "Add-on" = first fill of the other study drug while the index class is still covered by supply; "switch" = first fill of the other study drug after index supply (plus grace) has lapsed. Both censor the as-treated analysis. Fills of other antihypertensive classes do not censor.
  6. Washout list includes C02A/C02C/C02D/C09XA (central agents, alpha blockers, vasodilators, aliskiren) beyond the classes named in the request, because they are antihypertensive classes. Doxazosin is the only one present in PDE (1 fill).
  7. NDCs whose RxNorm history points to different drugs (17 NDCs, 829 fills, 0.7% of antihypertensive fills) take the union of classes; they are listed in `qc/ndc_antihtn_class_disagreement.csv`.
- **Status:** APPROVED 2026-10-20 (user instruction). Interpretations 1-7 CONFIRMED 2026-10-20 with two edits: **item 1** (diagnosis window: days -365 to 0 for eligibility; covariates stay -365 to -1) is superseded by A-009; **item 3** (ITT follow-up ends at loss of A+B only, last claim date as data end) is superseded by A-008. Outcome models were held until Checkpoint 3 was confirmed.

## A-006: Negative control code list also lists S72 codes without the 7th character

- **Date:** 2026-10-20 (Phase 3)
- **Protocol sections:** 7 (Outcomes, negative control), 15 (L1)
- **Issue:** Protocol 7 defines the negative control as ICD-10-CM S72 with initial-encounter 7th character A, B or C. The synthetic claims never carry a 7th character: the only femur-fracture code present is `S72009` (115 beneficiaries, 678 claims). With the pre-specified list the outcome could never be found (0 events by construction, not by chance).
- **Change:** `icd10_exclusions.csv` (role `negative_control_outcome`) now lists each initial-encounter S72 code both with its 7th character and as its 6-character parent. In these data the 7th character is unavailable, so initial and subsequent encounters cannot be told apart.
- **Status:** APPLIED 2026-10-20; CONFIRMED 2026-10-20. The negative control is reported descriptively only (counts and person-time; no model).

## A-007: As-treated analysis dropped as a secondary outcome (refill-interval evidence)

- **Date:** 2026-10-20 (Checkpoint 3 decision)
- **Protocol sections:** 2 (secondary objective 1), 9 (as-treated follow-up), 10.3 (IPCW), 11
- **Evidence (`qc/cohort/refill_pattern.csv`, `qc/cohort/timing_*.csv`, `docs/feasibility.qmd`; first seen at Checkpoint 3 on the 866-person v0.3 cohort and re-confirmed on the final 790-person cohort):** the index fill is a 90-day supply for essentially everyone. Of 790 cohort members, 649 have a second fill of the index class, and it comes a **median 371 days** after index (quartiles 364 to 371), i.e. one prescription renewal a year. Only 88 refilled within 120 days. A 30-day-grace discontinuation rule therefore flags 728 of 790 people (92%) as discontinued before any other event, and the cumulative incidence of discontinuation reaches 98% (ACE inhibitor) and 97% (thiazide) by day 365. IPCW cannot repair a censoring mechanism that applies to almost everyone.
- **Change:** the as-treated analysis with a discontinuation rule is **removed as a secondary outcome**. It is replaced by a **sensitivity analysis that censors only at add-on or switch to the other study drug (no discontinuation rule), with IPCW**. Discontinuation timing remains a descriptive table (T4), not a censoring rule.
- **Status:** APPROVED 2026-10-20.

## A-008: Intention-to-treat follow-up no longer ends at the last claim date

- **Date:** 2026-10-20
- **Protocol sections:** 9 (follow-up and censoring); supersedes A-005 interpretation 3
- **Change:** ITT follow-up ends only at the earliest of (1) loss of continuous Part A, B or D entitlement (end of the A+B+D span containing the index month), (2) end of data, taken as **2023-03-31** (the last day of the final data month; the last claim date is 2023-03-02), and (3) day 365. Previously follow-up also ended at the last claim date and at loss of A+B only. Anyone still enrolled is followed until the earliest of (2) and (3).
- **Consequences stated up front:** people indexed after 2022-03-31 cannot reach day 365 before the data end and are followed to 2023-03-31; no claims exist after 2023-03-02, so the last 29 days cannot show events. Loss of Part D now ends follow-up for the primary analysis as well as the sensitivity analyses (Part D coverage is about 70% of person-months). The number censored by each reason is reported by arm.
- **Sensitivity analyses added:** (i) ITT follow-up ending at loss of Part A+B only (ignoring Part D), (ii) the previous rule with data end 2023-03-02.
- **Status:** APPROVED 2026-10-20.

## A-009: Hypertension diagnosis for eligibility may fall on days -365 to 0

- **Date:** 2026-10-20
- **Protocol sections:** 5 (criterion 4), 8 (covariate window unchanged); supersedes A-005 interpretation 1
- **Clinical rationale:** hypertension is usually diagnosed at the visit that leads to the first prescription, so the diagnosis and the first fill commonly share a date. Requiring a diagnosis strictly before the index date would remove true new treatment starts and would favour people who had an earlier hypertension visit without treatment, a selected group. Eligibility therefore accepts a diagnosis on any claim from day -365 through the index date.
- **Change:** criterion 4 window = days -365 to 0. **Covariates remain measured in days -365 to -1**, so the index-date diagnosis is not used as a covariate. A sensitivity analysis uses the strict window (days -365 to -1).
- **Status:** APPROVED 2026-10-20.

## A-010: People starting another antihypertensive class on the index date are excluded (primary); sensitivity analyses

- **Date:** 2026-10-20
- **Protocol sections:** 5 (new exclusion criterion), 11
- **Reason:** people who start a second class with the study drug are not initiating the study drug alone; the comparison would mix mono- and combination therapy. At Checkpoint 3, 282 of the 866 members (33%) had another class filled on the index date.
- **Change:** new exclusion: no fill of any antihypertensive class other than the two study classes on the index date (a fixed-dose product containing another class counts). **Sensitivity analyses:** (i) keep these people, with an indicator covariate (`costart`); (ii) exclude everyone with any baseline fill that has no RxNorm record (new-user status uncertain).
- **Status:** APPROVED 2026-10-20.

## A-011: Phase 4 modelling specifications (applied; flagged for confirmation at Checkpoint 4)

- **Date:** 2026-10-20
- **Protocol sections:** 8, 10 (the protocol leaves these details open)
- **Propensity score model:** logistic regression of ACE-inhibitor initiation on age (linear and squared), sex, race, region, index year, index quarter, the CCW conditions COPD, asthma, ischemic heart disease, diabetes, chronic kidney disease and cancer, log(1 + visit days), any baseline hospitalization, number of distinct drugs and number of distinct drug classes (ATC level 4). Stabilized ATE weights, truncated at the 1st and 99th percentile of the weight distribution.
- **Coding choices:** (1) index **month is grouped into calendar quarter** (12 levels would be sparse); (2) **region** is the Census region derived from the SSA state code via `codelists/ssa_state_region.csv`, built from the official ResDAC/CCW MBSF codebook table and the Census Bureau state geocodes (see A-012); (3) factor levels with fewer than 10 people are pooled into "rare" and, if still under 10, merged into the most frequent level; (4) covariates with fewer than 10 people having (or lacking) the characteristic are **dropped from the model and reported**: heart failure (0 people) and dementia (8 people). Vaccination and ED visits are not identifiable in these data and are not covariates.
- **Weighted pooled logistic regression:** fitted to weighted person-days with a smooth time effect (natural spline, 4 df) and an arm-by-time interaction. Because weights are constant per person and the model has only time and arm, it is fitted on the equivalent per-day weighted counts. The 30-day risk is read from the same 365-day model. Weighted Kaplan-Meier risks are checked against `survival::survfit` in the unit tests.
- **Censoring in the ITT analyses:** loss of entitlement and end of data are treated as non-informative (no IPCW); IPCW is used only in the add-on/switch sensitivity analysis (A-007), with a censoring model on arm, age group and sex (few add-on/switch events), stabilized.
- **Bootstrap:** 500 resamples of individuals with replacement; the PS is refitted in every resample; percentile 95% intervals; seed 20261020. Matching is repeated inside every resample.
- **Verification:** my weights agree with `WeightIt` (stabilized ATE) and my standardized mean differences with `cobalt` (`qc/analysis/weightit_cobalt_check.csv`).
- **Status:** APPLIED 2026-10-20; CONFIRMED 2026-10-20.

## A-012: State-to-region mapping replaced by a code list built from official sources

- **Date:** 2026-10-20 (Checkpoint 4 follow-up)
- **Protocol sections:** 8 (region covariate); supersedes the hand-typed mapping used in the first Phase 4 run
- **Issue:** the first Phase 4 run used a state-code-to-region table typed from memory. Checked against the official table it was wrong for several codes (for example 49 is Virginia, 50 Washington, 51 West Virginia, 52 Wisconsin, 53 Wyoming, and 48 is the Virgin Islands).
- **Change:** `codelists/ssa_state_region.csv` is built by `codelists/build/build_state_region.py` from (1) the ResDAC / CCW MBSF codebook table "State Code for beneficiary (SSA code)" (V1.6, February 2024; downloaded 2026-10-20 from resdac.org) and (2) the U.S. Census Bureau state geocodes file (region assignment; release May 2021). Territories and foreign codes are "other"; carrier-area duplicate codes (67-74, 80) map to their named state. Every SSA state code present in the data is in the table. A unit test guards codes 48-53.
- **Consequence:** the region covariate changed for 54 of the 790 cohort members (the South-to-West and West-to-Midwest/South moves were the largest); all Phase 4 analyses were rerun.
- **Status:** APPLIED 2026-10-20; CONFIRMED 2026-10-21.

## A-013: Added sensitivity analysis: IPCW for loss of Part A/B/D entitlement

- **Date:** 2026-10-20 (Checkpoint 4 follow-up)
- **Protocol sections:** 9, 10.3, 11
- **Specification:** primary ITT outcome (365-day hospitalization), stabilized IPTW combined with stabilized IPCW for loss of continuous Part A/B/D entitlement. Censoring model: discrete-time (30-day intervals) logistic regression on interval, arm, age, sex, region, any baseline hospitalization, diabetes, chronic kidney disease and ischemic heart disease (kept short because the cohort has about 75 such censoring events); numerator model on interval and arm. Reaching the end of data or day 365 is administrative and not weighted. Bootstrap as for the other analyses (500 resamples; both models refitted in every resample).
- **Status:** APPLIED 2026-10-20; CONFIRMED 2026-10-21.

## Notes (not deviations)

- **Hospice file loaded.** Protocol 4 lists beneficiary, carrier, outpatient, inpatient and PDE, but exclusion 5.6 (hospice claim in baseline year) needs the hospice file, so it is ingested too.
- **Population size (explicit).** The files contain **9,179 distinct beneficiaries** across 2015-2023. The 8,671 quoted in the protocol is the 2022 reference-year count only (2023 has 9,179 rows).
- **Claim files are line-level.** Carrier has 1,121,004 rows for 90,705 distinct `CLM_ID`; outpatient 575,092 rows for 402,653 claims; inpatient 58,066 rows for 20,867 claims. Claim-level logic must deduplicate on `CLM_ID` (rows are not data errors; exact duplicate rows = 0).
