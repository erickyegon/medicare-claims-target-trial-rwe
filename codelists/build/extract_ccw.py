"""Extract the ICD-10 code lists for the protocol Section 8 conditions from the CCW
'30 CCW Chronic Conditions Algorithms' PDF (table extraction, no manual typing of codes).
Input : data/ref/ccw30_algorithms.pdf  (https://www2.ccwdata.org/documents/10280/19139421/chr-chronic-condition-algorithms.pdf)
Output: codelists/ccw_conditions.csv"""
import pdfplumber, re, csv, pathlib, datetime, sys
root = pathlib.Path(__file__).resolve().parents[2]
pdf = pdfplumber.open(root / "data/ref/ccw30_algorithms.pdf")
GROUP = {  # protocol Section 8 group -> CCW condition names (as printed in the PDF, whitespace-normalised)
  "copd": ["Chronic Obstructive Pulmonary Disease"], "asthma": ["Asthma"],
  "heart_failure": ["Heart Failure and Non-Ischemic Heart Disease"], "ischemic_heart_disease": ["Ischemic Heart Disease"],
  "diabetes": ["Diabetes"], "chronic_kidney_disease": ["Chronic Kidney Disease"], "hypertension": ["Hypertension"],
  "dementia": ["Alzheimer's Disease", "Non-Alzheimer's Dementia"],
  "cancer": ["Cancer, Breast", "Cancer, Colorectal", "Cancer, Endometrial", "Cancer, Lung", "Cancer, Prostate",
             "Cancer, Urologic (Kidney, Renal Pelvis, and Ureter)"]}
norm = lambda s: re.sub(r"\s+", " ", (s or "")).replace("- ", "-").strip()
rows = {}
for pg in pdf.pages:
    for t in pg.extract_tables():
        for r in t:
            if r and r[0] and len(r) == 8 and r[4]:
                rows[norm(r[0])] = (norm(r[1]), norm(r[4]), norm(r[5]))
CODE = re.compile(r"^[A-Z][0-9][0-9A-Z](\.[0-9A-Z]{1,4})?$")
out, missing, odd = [], [], []
for grp, names in GROUP.items():
    for n in names:
        if n not in rows: missing.append(n); continue
        look, codes, claims = rows[n]
        for tok in re.split(r"[,\s]+", re.sub(r"\([^)]*\)", " ", codes)):
            if not tok: continue
            if CODE.match(tok): out.append((grp, n, tok.replace(".", ""), tok, look, claims))
            else: odd.append((n, tok))
if missing: sys.exit(f"CCW conditions not found in PDF: {missing}")
today = datetime.date.today().isoformat()
with open(root / "codelists/ccw_conditions.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f); w.writerow(["protocol_group", "ccw_condition", "icd10_code", "icd10_dotted", "ccw_lookback", "ccw_claims_to_qualify", "source", "download_date"])
    for g, n, c, d, l, q in sorted(set(out)):
        w.writerow([g, n, c, d, l, q, "CCW 30 Chronic Conditions algorithms PDF (version 08/2026), ccwdata.org", today])
print(len(set(out)), "codes;", "unparsed tokens:", odd)

# ---- optional: all CCW conditions for the indication scan (does NOT touch codelists/ccw_conditions.csv) ----
if "--all" in sys.argv:
    allrows = []
    for n, (look, codes, claims) in rows.items():
        if n in ("Algorithms",) or n.startswith("Condition"): continue
        for tok in re.split(r"[,\s]+", re.sub(r"\([^)]*\)", " ", codes)):
            if tok and CODE.match(tok): allrows.append((n, tok.replace(".", "")))
    with open(root / "data/ref/ccw_all_conditions.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["ccw_condition", "icd10_code"]); w.writerows(sorted(set(allrows)))
    print("all-conditions file:", len(set(allrows)), "codes,", len({r[0] for r in allrows}), "conditions")
