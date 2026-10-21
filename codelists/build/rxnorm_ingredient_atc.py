"""Map PDE NDCs -> RxNorm ingredient(s) -> ATC level-4 class (RxClass) for the indication scan.

Input : data/ref/rxnorm_pde_resolution.csv (NDC -> RxCUI(s), from rxnorm_resolve_pde_ndcs.py)
Output: data/ref/rxnorm_rxcui_ingredient.csv   rxcui, ingredient_rxcui, ingredient_name
        data/ref/rxnorm_rxcui_drug.csv         rxcui, drug_name (sorted ingredients), n_ingredients, min_rxcui
        data/ref/rxnorm_rxcui_atc.csv          rxcui, atc_id, atc_name, class_source  (ATC level 4 via RxClass; MIN class for combinations)
Resumable: every API answer is cached in data/ref/rxnorm_cache2/. Only RxCUIs / ingredient names are exchanged with NLM."""
import csv, json, pathlib, re, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
root = pathlib.Path(__file__).resolve().parents[2]
cache = root / "data/ref/rxnorm_cache2"; cache.mkdir(parents=True, exist_ok=True)
BASE = "https://rxnav.nlm.nih.gov/REST"

def get(path):
    f = cache / (re.sub(r"[^A-Za-z0-9._-]", "_", path) + ".json")
    if f.exists(): return json.loads(f.read_text())
    for attempt in range(6):
        try:
            with urllib.request.urlopen(BASE + path, timeout=60) as r: data = json.loads(r.read().decode())
            f.write_text(json.dumps(data)); time.sleep(0.15); return data
        except Exception:
            time.sleep(1.5 * 2 ** attempt)
    return {"_error": True}

res = list(csv.DictReader(open(root / "data/ref/rxnorm_pde_resolution.csv")))
cuis = sorted({c for r in res if r["resolved"] == "True" for c in r["rxcuis"].split(";") if c})
print(len(cuis), "distinct RxCUIs", flush=True)

def ingredients(cui):
    props = get(f"/rxcui/{cui}/properties.json").get("properties")
    if not props: return cui, []
    if props["tty"] == "IN": return cui, [(cui, props["name"])]
    js = get(f"/rxcui/{cui}/related.json?tty=IN")
    out = []
    for g in js.get("relatedGroup", {}).get("conceptGroup", []):
        out += [(p["rxcui"], p["name"]) for p in g.get("conceptProperties", [])]
    return cui, out

rows, errors = [], 0
with ThreadPoolExecutor(4) as ex:
    for i, (cui, ings) in enumerate(ex.map(ingredients, cuis), 1):
        for ic, nm in ings: rows.append((cui, ic, nm))
        if i % 500 == 0: print(i, "rxcuis done", flush=True)
with open(root / "data/ref/rxnorm_rxcui_ingredient.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["rxcui", "ingredient_rxcui", "ingredient_name"]); w.writerows(rows)
ings = sorted({(r[1], r[2]) for r in rows})
print(len(ings), "distinct ingredients", flush=True)

def classes_of(cui, names_ok):
    """ATC level 1-4 classes RxClass attaches to this concept itself (IN / MIN), or to its salt form (PIN) for single ingredients."""
    js = get(f"/rxclass/class/byRxcui.json?rxcui={cui}&relaSource=ATC")
    out = []
    for d in js.get("rxclassDrugInfoList", {}).get("rxclassDrugInfo", []):
        mc, c = d["minConcept"], d["rxclassMinConceptItem"]
        if mc["rxcui"] == cui or (mc["tty"] == "PIN" and names_ok):
            out.append((c["classId"], c["className"]))
    return sorted(set(out))

by_cui = {}
for cui, ic, nm in rows: by_cui.setdefault(cui, []).append((ic, nm))
drug_rows, atc_rows = [], []
def per_product(cui):
    ings_ = sorted(set(by_cui[cui]), key=lambda x: x[1]); name = " / ".join(n for _, n in ings_)
    if len(ings_) == 1:
        return cui, name, "", classes_of(ings_[0][0], True), "IN"
    min_cui = ""
    for g in get(f"/rxcui/{cui}/related.json?tty=MIN").get("relatedGroup", {}).get("conceptGroup", []):
        for p in g.get("conceptProperties", []):
            if p["name"].lower() == name.lower() or not min_cui: min_cui = p["rxcui"]
    cl = classes_of(min_cui, False) if min_cui else []
    if cl: return cui, name, min_cui, cl, "MIN"
    return cui, name, min_cui, sorted({c for ic, _ in ings_ for c in classes_of(ic, True)}), "IN-union"
with ThreadPoolExecutor(4) as ex:
    for i, (cui, name, min_cui, cl, src) in enumerate(ex.map(per_product, sorted(by_cui)), 1):
        drug_rows.append((cui, name, len(by_cui[cui]), min_cui))
        atc_rows += [(cui, a, n, src) for a, n in cl]
        if i % 100 == 0: print(i, "products done", flush=True)
with open(root / "data/ref/rxnorm_rxcui_drug.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["rxcui", "drug_name", "n_ingredients", "min_rxcui"]); w.writerows(drug_rows)
with open(root / "data/ref/rxnorm_rxcui_atc.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["rxcui", "atc_id", "atc_name", "class_source"]); w.writerows(atc_rows)
print("finished")
