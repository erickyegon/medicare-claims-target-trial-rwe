"""Ingredient lists for the hypertension study (amendment A-005) from RxClass (ATC) via the NLM RxNav API.

Study drugs   : ACEI = ATC C09AA (ACE inhibitors, plain);  THIAZIDE = C03AA (thiazides, plain) + C03BA (sulfonamide thiazide-like diuretics, plain)
Washout (new-user definition, any antihypertensive class): study classes plus
  ARB C09CA | CCB C08 (all calcium channel blockers) | BB C07A (all beta blockers) | LOOP C03C | OTHER_DIURETIC C03D + C03E |
  OTHER_ANTIHTN C02A, C02C, C02D, C09XA (central agents, alpha blockers, vasodilators, renin inhibitors).
  C02K ("other antihypertensives": mostly pulmonary-hypertension drugs) and C03X (vaptans etc.) are deliberately left out.
Output: data/ref/rxclass_antihtn_members.csv (class label, ATC id, ingredient RxCUI, ingredient name, retrieval date)."""
import csv, datetime, json, pathlib, urllib.request, time
root = pathlib.Path(__file__).resolve().parents[2]
CLASSES = [("ACEI", ["C09AA"]), ("THIAZIDE", ["C03AA", "C03BA"]), ("ARB", ["C09CA"]), ("CCB", ["C08"]), ("BB", ["C07A"]),
           ("LOOP", ["C03C"]), ("OTHER_DIURETIC", ["C03D", "C03E"]), ("OTHER_ANTIHTN", ["C02A", "C02C", "C02D", "C09XA"])]
rows = []
for label, atcs in CLASSES:
    for atc in atcs:
        for attempt in range(5):
            try:
                with urllib.request.urlopen(f"https://rxnav.nlm.nih.gov/REST/rxclass/classMembers.json?classId={atc}&relaSource=ATC&ttys=IN", timeout=60) as r:
                    js = json.loads(r.read().decode())
                break
            except Exception:
                time.sleep(2 ** attempt)
        else:
            raise SystemExit(f"RxClass request failed for {atc}")
        members = js.get("drugMemberGroup", {}).get("drugMember", [])
        for m in members:
            mc = m["minConcept"]; rows.append((label, atc, mc["rxcui"], mc["name"], datetime.date.today().isoformat()))
        print(label, atc, len(members), flush=True)
rows = sorted(set(rows))
with open(root / "data/ref/rxclass_antihtn_members.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["ahtn_class", "atc_id", "ingredient_rxcui", "ingredient_name", "retrieved"]); w.writerows(rows)
print(len(rows), "rows;", len({r[2] for r in rows}), "distinct ingredients")
