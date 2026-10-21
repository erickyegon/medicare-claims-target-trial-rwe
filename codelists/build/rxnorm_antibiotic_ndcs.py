"""Historical NDCs for the protocol Section 6 antibiotics from RxNorm (NLM RxNav REST API).

Why: the FDA NDC Directory only lists currently marketed products, but the synthetic PDE file uses
historical NDCs (only ~13% of PDE NDCs are in the current directory). RxNorm keeps retired NDCs.

Steps per ingredient: ingredient RxCUI -> oral clinical drugs (SCD/SBD) -> all historical NDCs per drug.
Responses are cached in data/ref/rxnorm_cache/ so the script is resumable and re-runs offline.
Output: data/ref/rxnorm_ndcs.csv (read by R/03_codelists.R)."""
import csv, json, pathlib, re, sys, time, urllib.parse, urllib.request, datetime
from concurrent.futures import ThreadPoolExecutor

root = pathlib.Path(__file__).resolve().parents[2]
cache = root / "data/ref/rxnorm_cache"; cache.mkdir(parents=True, exist_ok=True)
BASE = "https://rxnav.nlm.nih.gov/REST"
# (generic label used in the list, class, RxNorm ingredient name)
INGREDIENTS = [("amoxicillin", "penicillin", "amoxicillin"), ("amoxicillin-clavulanate", "penicillin", "amoxicillin"),
               ("azithromycin", "macrolide", "azithromycin"), ("clarithromycin", "macrolide", "clarithromycin"),
               ("doxycycline", "tetracycline", "doxycycline"), ("cephalexin", "cephalosporin", "cephalexin"),
               ("cefuroxime axetil", "cephalosporin", "cefuroxime"), ("cefdinir", "cephalosporin", "cefdinir"),
               ("cefpodoxime", "cephalosporin", "cefpodoxime"), ("levofloxacin", "fluoroquinolone", "levofloxacin"),
               ("moxifloxacin", "fluoroquinolone", "moxifloxacin"),
               ("sulfamethoxazole-trimethoprim", "sulfonamide", "sulfamethoxazole")]
ORAL = re.compile(r"\b(Oral|Chewable)\b", re.I)
NOT_ORAL = re.compile(r"Injectable|Injection|Ophthalmic|Otic|Topical|Vaginal|Intravenous|Inhal|Pack|Kit|Cream|Ointment|Gel|Solution Drops|Intramuscular", re.I)

def get(path, key):
    f = cache / (re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".json")
    if f.exists(): return json.loads(f.read_text())
    for attempt in range(5):
        try:
            with urllib.request.urlopen(BASE + path, timeout=60) as r: data = json.loads(r.read().decode())
            f.write_text(json.dumps(data)); time.sleep(0.08); return data
        except Exception as e:
            time.sleep(2 ** attempt)
    sys.exit(f"RxNav request failed after retries: {path}")

def concepts(js):
    out = []
    for g in js.get("relatedGroup", {}).get("conceptGroup", []):
        out += g.get("conceptProperties", [])
    return out

def classify(generic, name):
    """Does an RxNorm drug name belong to this protocol generic? Ingredient set is read off the name."""
    n = name.lower(); multi = " / " in n
    if not ORAL.search(name) or NOT_ORAL.search(name): return False
    if generic == "amoxicillin": return n.startswith("amoxicillin") and not multi
    if generic == "amoxicillin-clavulanate": return "amoxicillin" in n and "clavulan" in n and n.count(" / ") == 1
    if generic == "sulfamethoxazole-trimethoprim": return "sulfamethoxazole" in n and "trimethoprim" in n and n.count(" / ") == 1
    if generic == "doxycycline": return n.startswith("doxycycline") and not multi and not n.startswith("doxycycline 20 mg")
    if generic == "cefuroxime axetil": return n.startswith("cefuroxime") and not multi
    return n.startswith(generic.split()[0]) and not multi

rows, summary = [], []
for generic, klass, ing in INGREDIENTS:
    rx = get(f"/rxcui.json?name={urllib.parse.quote(ing)}&search=1", f"rxcui_{ing}")["idGroup"].get("rxnormId", [])
    prop = [get(f"/rxcui/{r}/properties.json", f"prop_{r}")["properties"] for r in rx]
    in_cui = [p["rxcui"] for p in prop if p["tty"] == "IN" and p["name"].lower() == ing]
    if len(in_cui) != 1: sys.exit(f"cannot resolve a single ingredient RxCUI for {ing}: {prop}")
    drugs = concepts(get(f"/rxcui/{in_cui[0]}/related.json?tty=SCD+SBD", f"related_{in_cui[0]}"))
    keep = [d for d in drugs if classify(generic, d["name"])]
    def hist(d):
        js = get(f"/rxcui/{d['rxcui']}/allhistoricalndcs.json?history=1", f"hist_{d['rxcui']}")
        out = []
        for t in js.get("historicalNdcConcept", {}).get("historicalNdcTime", []):
            for nt in t.get("ndcTime", []):
                for ndc in nt.get("ndc", []): out.append((ndc, nt.get("startDate", ""), nt.get("endDate", "")))
        return out
    with ThreadPoolExecutor(6) as ex: hists = list(ex.map(hist, keep))
    n0 = len(rows)
    for d, h in zip(keep, hists):
        for ndc, s, e in h:
            rows.append([ndc, generic, klass, d["rxcui"], d["tty"], d["name"], s, e])
    summary.append((generic, len(drugs), len(keep), len(rows) - n0)); print(summary[-1], flush=True)

bad = [r for r in rows if not re.fullmatch(r"\d{11}", r[0])]
if bad: print("WARNING non-11-digit NDCs from RxNorm:", len(bad), bad[:3])
rows = [r for r in rows if re.fullmatch(r"\d{11}", r[0])]
with open(root / "data/ref/rxnorm_ndcs.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f); w.writerow(["ndc11", "generic", "class", "rxcui", "tty", "rxnorm_name", "ndc_start", "ndc_end"]); w.writerows(rows)
print("rows", len(rows), "distinct ndc11", len({r[0] for r in rows}), "downloaded", datetime.date.today())
