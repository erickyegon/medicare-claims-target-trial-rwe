# Feasibility findings (profiling pass, 2026-10-20)

Source: CMS Synthetic Medicare Enrollment, FFS Claims and PDE (67,257 beneficiary-years; claims 2015-03 to 2023-03).

| Protocol assumption | Finding | Consequence |
|---|---|---|
| Influenza (J09-J11) diagnoses exist | **0 claims** in carrier, outpatient, inpatient | Original question not estimable |
| Oseltamivir fills in PDE | **0** fills for Tamiflu NDCs (00004-080x/081x); PDE has NDC only, no drug names | Needs NDC directory lookup for any drug-specific exposure |
| Mortality outcome | **0** death dates in all beneficiary files | Drop mortality (as predicted by CMS guide) |
| Peramivir HCPCS J2547 | 0 | n/a |
| Respiratory signal that does exist | J32.9 chronic sinusitis (4.4k benes), J20.9 acute bronchitis (2.4k), J02.9 pharyngitis (1.4k), J03.90 tonsillitis (1.3k), COPD J43/J44 (~300) | Candidate pivot conditions |
| Acute bronchitis (J20.9) index events | ~250-320 beneficiaries/year; ~70% have any Part D fill within 0-2 d; ~55/yr with a 5-10 day supply | Small but workable for a methods demo |
