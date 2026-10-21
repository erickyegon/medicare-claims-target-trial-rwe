# Code lists

All lists carry `source` and `download_date` columns. Built by `R/03_codelists.R` (ICD, NDC, revenue centers) and
`codelists/build/*.py` (CCW extraction, RxNorm NDC pull). Reference downloads live in `data/ref/` (git-ignored).

| File | Content | Source |
|---|---|---|
| `icd10_bronchitis.csv` | J20.0-J20.9 (10 billable codes) | ICD-10-CM FY2023 table (CMS) |
| `icd10_exclusions.csv` | pneumonia J12-J18, sinusitis J01, pharyngitis/tonsillitis J02-J03, otitis media H65-H66, UTI N39.0, skin infection L03, negative-control femur fracture S72 (initial encounter) with a `role` column | ICD-10-CM FY2023 table |
| `ccw_conditions.csv` | ICD-10 lists for COPD, asthma, heart failure, IHD, diabetes, CKD, hypertension, dementia, cancer | CCW "30 Chronic Conditions" algorithms PDF (08/2026 version) |
| `ndc_antibiotics.csv` | 11-digit NDCs for oral amoxicillin, amoxicillin-clavulanate, azithromycin, clarithromycin, doxycycline, cephalexin, cefuroxime, cefdinir, cefpodoxime, levofloxacin, moxifloxacin, SMX-TMP | FDA NDC Directory + RxNorm historical NDCs |
| `antihypertensive_ingredients.csv` | Study-drug (ACE inhibitor C09AA; thiazide / thiazide-like C03AA, C03BA) and washout ingredients (ARB, CCB, beta blocker, loop and other diuretics, other antihypertensives) | RxClass ATC class members via RxNav |
| `icd10_hypertension.csv` | I10-I16 (17 billable codes) | ICD-10-CM FY2023 table |
| `ndc_antihypertensive.csv` | PDE NDCs mapped to those classes (one row per NDC and class; a combination product has several) | RxNorm NDC history + RxClass |
| `ndc_resolved.csv` | PDE NDCs with an RxNorm record (all others have no RxNorm record, measure 1) | RxNorm |
| `revenue_center_ed.csv` | 0450-0459, 0981 (documented; not populated in the data, see A-001) | protocol Section 7 |

Negative-control femur fracture codes are listed with and without the 7th character (amendment A-006). The antibiotic list (`ndc_antibiotics.csv`) belongs to the v0.2 bronchitis analysis, which was not run (A-004).

Notes on the NDC list: 20 mg doxycycline (sub-antimicrobial periodontitis dose) is excluded; single-ingredient trimethoprim is not in the protocol classes and is excluded; only oral routes are kept; kits and injectables are dropped.
