# Profiling notes (Checkpoint 1 follow-up)

## Inpatient admission type (`CLM_IP_ADMSN_TYPE_CD`), 20,867 claims. NOT used in the pipeline.
- Overall: 1 (emergency) 78.5%, 2 (urgent) 3.2%, 3 (elective) 18.4%. Code 4+ absent.
- **Looks modelled, not random, with respect to diagnosis:** association with principal-diagnosis chapter is strong (Cramer's V = 0.41, chi-square p < 1e-300; some small cells so treat the p-value as indicative only). Neoplasm admissions are 99% elective; "urgent" appears almost only for circulatory, injury, digestive and musculoskeletal chapters; infectious admissions are 99% emergency.
- **Admission source (`CLM_SRC_IP_ADMSN_CD`) looks random:** uniform over 1/2/4/5 and independent of admission type (Cramer's V = 0.011, p = 0.49).
- Caveat: 13,000 of 20,867 admissions have a Z-code or injury (S/T) principal diagnosis, which is not clinically realistic; the type code follows the generator's encounter logic rather than real emergency/elective patterns. Elective share is ~16-17% in 2015-2019 and ~23% from 2020.
- Within beneficiaries with 2+ admissions, 1,744 of 3,496 have mixed types.
Conclusion: usable as a descriptor of the synthetic encounter, but do not interpret as a clinical severity marker.

## Outpatient revenue/HCPCS and index setting
See amendment A-002.

## PDE NDC identification (RxNorm resolution, `codelists/build/rxnorm_resolve_pde_ndcs.py`, 2026-10-20)
- Of 14,627 distinct PDE NDCs, RxNorm resolved 11,913 (81%) covering 414,113 of 515,520 fills (80.3%); 2,714 NDCs (101,407 fills, 19.7%) are unknown to RxNorm. The FDA directory alone identified only 14.1% of fills.
- Among fills dispensed 0-2 days after a person's first bronchitis claim (since 2016-03), 1,272 had a resolvable NDC and 402 (24%) did not. No protocol-listed antibiotic appears in the resolvable portion; antibiotic use in the unresolvable 24% cannot be excluded.
