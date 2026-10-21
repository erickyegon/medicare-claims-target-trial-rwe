"""Narrative audit: every number quoted in the static prose (amendments, protocol, notes, scan report) is recomputed from the database or the
aggregate CSVs and checked against the text. Quarto documents that use inline R (feasibility, study report) are generated from the CSVs and are
not audited here. Run from the project root:  python qc/narrative_audit.py   (writes qc/narrative_audit.csv; exit code 1 if any check fails)."""
import duckdb, pandas as pd, pathlib, re, sys
root = pathlib.Path(__file__).resolve().parents[1]
con = duckdb.connect(str(root / "data/medicare.duckdb"), read_only=True)
txt = lambda f: (root / f).read_text(encoding="utf-8")
amend, protocol, notes, scanq = txt("docs/amendments.md"), txt("docs/protocol.md"), txt("qc/profiling_notes.md"), txt("qc/indication_scan.qmd")
q = lambda s: con.execute(s).fetchone()[0]
rows = []
def check(label, doc_name, doc, literal, actual, expected_literal=None):
    """`literal`: the string as it appears in the text; `actual`: the recomputed value (formatted the same way)."""
    present = literal in doc
    ok = present and str(actual) == str(expected_literal if expected_literal is not None else literal.replace(",", ""))
    rows.append((doc_name, label, literal, actual, "PASS" if ok else ("TEXT MISSING" if not present else "MISMATCH")))
f = lambda n: f"{int(n):,}"

# --- A-001 / A-002 (profiling of outpatient and carrier files) ---
check("outpatient rows", "amendments", amend, "575,092 rows", q("select count(*) from outpatient"), "575092")
n0001 = q("select count(*) from outpatient where REV_CNTR='0001'"); check("rev 0001 rows", "amendments", amend, "0001 on 574,480 rows", n0001, "574480")
check("rev 0780/0789 rows", "amendments", amend, "0780 and 0789 on 612 rows", q("select count(*) from outpatient where REV_CNTR in ('0780','0789')"), "612")
check("ED revenue rows", "amendments", amend, "**0 rows** in 0450-0459 or 0981", q("select count(*) from outpatient where REV_CNTR between '0450' and '0459' or REV_CNTR='0981'"), "0")
dx = lambda k: " OR ".join([f"ICD_DGNS_CD{i} LIKE 'J20%'" for i in range(1, k + 1)] + ["PRNCPAL_DGNS_CD LIKE 'J20%'"])
check("bronchitis outpatient claims", "amendments", amend, "8,768 outpatient claims", q(f"select count(distinct CLM_ID) from outpatient where {dx(25)}"), "8768")
check("bronchitis outpatient benes", "amendments", amend, "(2,494 beneficiaries)", q(f"select count(distinct BENE_ID) from outpatient where {dx(25)}"), "2494")
check("bronchitis carrier claims", "amendments", amend, "only 1,015 carrier claims", q(f"select count(distinct CLM_ID) from carrier where {dx(12)}"), "1015")
check("bronchitis carrier benes", "amendments", amend, "(657 beneficiaries)", q(f"select count(distinct BENE_ID) from carrier where {dx(12)}"), "657")
pos11 = q("select 100.0*count(*) filter (where LINE_PLACE_OF_SRVC_CD='11')/count(*) from carrier"); check("POS 11 share (83%)", "amendments", amend, "11 (office) on 83% of lines", round(pos11), "83")
r1 = q("select 100.0*count(*) filter (where REV_CNTR='0001')/count(*) from outpatient"); check("rev 0001 share (99.9%)", "amendments", amend, "99.9% of lines have revenue code 0001", round(r1, 1), "99.9")
# --- A-004 (NDC identification) ---
res = pd.read_csv(root / "data/ref/rxnorm_pde_resolution.csv", dtype=str)
check("PDE distinct NDCs", "amendments", amend, "14,627 distinct PDE NDCs", len(res), "14627")
nres = int((res.resolved == "True").sum()); check("resolved NDCs", "amendments", amend, "11,913 (81.4%)", f"{nres} ({100*nres/len(res):.1f}%)", "11913 (81.4%)")
check("unresolved NDCs", "amendments", amend, "2,714 (18.6%)", f"{len(res)-nres} ({100*(len(res)-nres)/len(res):.1f}%)", "2714 (18.6%)")
con.register("res", res)
fills = q("select count(*) from pde"); fr = q("select count(*) from pde p join res r on r.ndc11=p.PROD_SRVC_ID where r.resolved='True'")
check("PDE fills", "amendments", amend, "All PDE fills (515,520)", fills, "515520")
check("resolved fills", "amendments", amend, "414,113 (80.3%)", f"{fr} ({100*fr/fills:.1f}%)", "414113 (80.3%)")
check("unresolved fills", "amendments", amend, "101,407 (19.7%)", f"{fills-fr} ({100*(fills-fr)/fills:.1f}%)", "101407 (19.7%)")
m = pd.read_csv(root / "qc/pde_directory_coverage.csv").iloc[0]
check("FDA directory coverage", "amendments", amend, "only 14.1% of fills (72,693)", f"{100*m.fills_found/m.fills_total:.1f}% ({int(m.fills_found)})", "14.1% (72693)")
ms = pd.read_csv(root / "qc/ndc_match_summary.csv").iloc[0]
check("listed-antibiotic fills", "amendments", amend, "(1,672 listed-antibiotic fills in total, 0.3%)", f"({int(ms.pde_fills_matched)} listed-antibiotic fills in total, {100*ms.pde_fills_matched/ms.pde_fills_total:.1f}%)", "(1672 listed-antibiotic fills in total, 0.3%)")
ab = pd.read_csv(root / "codelists/ndc_antibiotics.csv", dtype=str, usecols=["ndc11"]).ndc11.nunique()
check("antibiotic NDC list size", "amendments", amend, "18,015 eleven-digit NDCs", ab, "18015")
# --- A-005 item 7 (NDCs with disagreeing RxNorm histories) ---
dis = pd.read_csv(root / "qc/ndc_antihtn_class_disagreement.csv", dtype=str); fills_by = con.execute("select PROD_SRVC_ID n, count(*) c from pde group by 1").df().set_index("n").c
ndcs = dis.ndc11.unique(); fsum = int(fills_by.reindex(ndcs).sum())
ah = pd.read_csv(root / "codelists/ndc_antihypertensive.csv", dtype=str).ndc11.unique(); allf = int(fills_by.reindex(ah).sum())
check("disagreeing NDCs", "amendments", amend, "17 NDCs, 829 fills, 0.7% of antihypertensive fills", f"{len(ndcs)} NDCs, {fsum} fills, {100*fsum/allf:.1f}% of antihypertensive fills", "17 NDCs, 829 fills, 0.7% of antihypertensive fills")
# --- A-006 ---
check("S72009 persons/claims", "amendments", amend, "`S72009` (115 beneficiaries, 678 claims)", f"`S72009` ({q(chr(115)+'elect count(distinct BENE_ID) from dx_long where code=' + chr(39) + 'S72009' + chr(39))} beneficiaries, {q('select count(distinct CLM_ID) from dx_long where code=' + chr(39) + 'S72009' + chr(39))} claims)", "`S72009` (115 beneficiaries, 678 claims)")
# --- A-011 (rare covariates) and A-012 (region) ---
b = con.execute("select * from base_primary").df()
check("heart failure people", "amendments", amend, "heart failure (0 people)", f"heart failure ({int(b.heart_failure.sum())} people)", "heart failure (0 people)")
check("dementia people", "amendments", amend, "dementia (8 people)", f"dementia ({int(b.dementia.sum())} people)", "dementia (8 people)")
check("final cohort size", "amendments", amend, "54 of the 790 cohort members", f"54 of the {len(b)} cohort members", "54 of the 790 cohort members")
# --- notes: inpatient admission type ---
ip = pd.read_csv(root / "qc/profile_ip_overall.csv"); sh = {int(r.adm_type): r.pct for r in ip.itertuples()}
check("admission type shares", "profiling_notes", notes, "1 (emergency) 78.5%, 2 (urgent) 3.2%, 3 (elective) 18.4%", f"1 (emergency) {sh[1]}%, 2 (urgent) {sh[2]}%, 3 (elective) {sh[3]}%", "1 (emergency) 78.5%, 2 (urgent) 3.2%, 3 (elective) 18.4%")
cv = pd.read_csv(root / "qc/profile_ip_chisq_chapter.csv").cramers_v[0]; check("Cramer V chapter", "profiling_notes", notes, "Cramer's V = 0.41", f"Cramer's V = {cv:.2f}", "Cramer's V = 0.41")
cs = pd.read_csv(root / "qc/profile_ip_chisq_source.csv"); check("Cramer V source", "profiling_notes", notes, "Cramer's V = 0.011, p = 0.49", f"Cramer's V = {cs.cramers_v[0]:.3f}, p = {cs.p[0]:.2f}", "Cramer's V = 0.011, p = 0.49")
# --- scan report static claims ---
cc = pd.read_csv(root / "qc/scan/chronic_condition_classes.csv")
none = [c for c in ["Chronic Obstructive Pulmonary Disease", "Asthma", "Heart Failure and Non-Ischemic Heart Disease"] if c not in set(cc.cond)]
check("no classes for COPD/asthma/HF", "scan report", scanq, "no new-user classes for COPD, asthma or heart failure", "no new-user classes for COPD, asthma or heart failure" if len(none) == 3 else "classes exist", "no new-user classes for COPD, asthma or heart failure")
out = pd.DataFrame(rows, columns=["document", "claim", "text", "recomputed", "result"]); out.to_csv(root / "qc/narrative_audit.csv", index=False)
print(out.assign(text=out.text.str[:60], recomputed=out.recomputed.astype(str).str[:40]).to_string(index=False))
print("\nFAILED:", int((out.result != "PASS").sum()), "of", len(out)); sys.exit(0 if (out.result == "PASS").all() else 1)
