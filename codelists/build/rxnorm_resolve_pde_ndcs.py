"""Coverage diagnostic: can RxNorm identify the NDCs that appear in the synthetic PDE file?
Reads distinct PDE NDCs from the DuckDB database, asks RxNav ndcproperties (ndcstatus=ALL, so retired NDCs
are included) and records the RxCUI(s) found. Resumable; results in data/ref/rxnorm_pde_resolution.csv.
Only NDC codes (synthetic, non-sensitive) are sent to the NLM service."""
import csv, json, pathlib, sys, time, urllib.request, duckdb
from concurrent.futures import ThreadPoolExecutor
root = pathlib.Path(__file__).resolve().parents[2]
out = root / "data/ref/rxnorm_pde_resolution.csv"
con = duckdb.connect(str(root / "data/medicare.duckdb"), read_only=True)
ndcs = [r[0] for r in con.execute("SELECT DISTINCT PROD_SRVC_ID FROM pde ORDER BY 1").fetchall()]
done = {}
if out.exists():
    with open(out, newline="") as f:
        done = {r["ndc11"]: r for r in csv.DictReader(f)}
todo = [n for n in ndcs if n not in done]
print(len(ndcs), "PDE NDCs;", len(todo), "to resolve", flush=True)

def resolve(n):
    for attempt in range(5):
        try:
            with urllib.request.urlopen(f"https://rxnav.nlm.nih.gov/REST/ndcproperties.json?id={n}&ndcstatus=ALL", timeout=60) as r:
                js = json.loads(r.read().decode())
            props = js.get("ndcPropertyList", {}).get("ndcProperty", [])
            cuis = sorted({p["rxcui"] for p in props if p.get("rxcui")})
            status = sorted({v["propValue"] for p in props for v in p.get("propertyConceptList", {}).get("propertyConcept", []) if v["propName"] == "MARKETING_STATUS"})
            time.sleep(0.1)
            return {"ndc11": n, "resolved": bool(cuis), "rxcuis": ";".join(cuis), "marketing_status": ";".join(status)}
        except Exception:
            time.sleep(2 ** attempt)
    return {"ndc11": n, "resolved": "ERROR", "rxcuis": "", "marketing_status": ""}

new = not out.exists()
with open(out, "a", newline="") as f, ThreadPoolExecutor(8) as ex:
    w = csv.DictWriter(f, fieldnames=["ndc11", "resolved", "rxcuis", "marketing_status"])
    if new: w.writeheader()
    for i, row in enumerate(ex.map(resolve, todo), 1):
        w.writerow(row)
        if i % 500 == 0: f.flush(); print(i, "done", flush=True)
print("finished")
