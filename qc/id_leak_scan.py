"""Pre-commit scan: no record-level identifiers may be tracked.
Builds the sets of real BENE_ID, CLM_ID and PDE_ID values from data/raw (never written anywhere), then checks every file git would track
(`git ls-files`, so run `git add -A` first) for
  (a) ID VALUES: any token equal to a real BENE_ID / CLM_ID / PDE_ID (with or without a leading minus sign);
  (b) ID COLUMNS: a data file (csv/tsv/txt/json) whose header row has a column named BENE_ID, CLM_ID or PDE_ID;
(d) ABSOLUTE PATHS: any machine-specific path (C:/, C:\, /Users/, /home/<name>/) in a tracked text file;
and reports separately (c) harmless mentions of the column NAMES inside code and documents, or as a cell value in a metadata file.
Run from the project root:  python qc/id_leak_scan.py      (writes qc/id_scan_report.csv; exit code 1 if (a), (b) or (d) finds anything)."""
import pathlib, re, subprocess, sys
import pandas as pd
root = pathlib.Path(__file__).resolve().parents[1]
raw = root / "data/raw"

# ---- real identifier sets -------------------------------------------------------------------------------------------------
def ids(files, col):
    out = set()
    for f in files:
        if not f.exists(): continue
        for chunk in pd.read_csv(f, sep="|", usecols=[col], dtype=str, chunksize=500_000):
            out.update(chunk[col].dropna().unique())
    return out
bene = ids(sorted(raw.glob("beneficiary_20*.csv")), "BENE_ID")
clm = ids([raw / "carrier/carrier.csv", raw / "outpatient/outpatient.csv", raw / "inpatient.csv", raw / "hospice.csv", raw / "snf.csv", raw / "hha.csv", raw / "dme.csv"], "CLM_ID")
pde = ids([raw / "pde.csv"], "PDE_ID")
sets = {"BENE_ID": bene, "CLM_ID": clm, "PDE_ID": pde}
both = {k: v | {x.lstrip("-") for x in v} for k, v in sets.items()}          # match with and without the minus sign
print({k: len(v) for k, v in sets.items()}, "real identifiers loaded")
assert all(len(v) > 1000 for v in sets.values()), "identifier sets are suspiciously small: is data/raw present?"

# ---- files git would track -----------------------------------------------------------------------------------------------------
tracked = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout.split("\n")
tracked = [t for t in tracked if t]
BINARY = {".png", ".jpg", ".gif", ".rds", ".rda", ".duckdb", ".pdf", ".xlsx", ".zip", ".ico"}
DATA = {".csv", ".tsv", ".txt", ".json", ".lock"}
tok = re.compile(r"-?\d{6,}")
abs_path = re.compile(r"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\/]|/Users/|/home/(?!&sysuserid)[A-Za-z0-9_.-]+/)")   # machine-specific absolute paths (C:/, C:\, /Users/, /home/<name>/)
hits_abs = []
rows, hits_values, hits_cols = [], [], []
for rel in tracked:
    p = root / rel; ext = p.suffix.lower()
    if ext in BINARY:
        rows.append((rel, "binary (not text-scanned)", "", "")); continue
    text = p.read_bytes().decode("latin-1")
    # (a) identifier values
    found = {}
    for t in set(tok.findall(text)):
        for k, s in both.items():
            if t in s or t.lstrip("-") in s: found.setdefault(k, set()).add(t)
    if found:
        hits_values.append(rel); rows.append((rel, "ID VALUE FOUND", ",".join(found), "; ".join(f"{k}:{len(v)}" for k, v in found.items())))
    # (d) absolute paths of the author's machine
    if abs_path.search(text) and rel != "qc/id_leak_scan.py":
        ex = abs_path.search(text); hits_abs.append(rel)
        rows.append((rel, "ABSOLUTE PATH", "", text[ex.start():ex.start() + 40].splitlines()[0]))
    # (b) identifier columns in data files
    first = text.split("\n", 1)[0]
    cols = [c.strip().strip('"').upper() for c in re.split(r"[|,\t]", first)]
    id_cols = [c for c in ("BENE_ID", "CLM_ID", "PDE_ID") if c in cols]
    if ext in DATA and id_cols:
        hits_cols.append(rel); rows.append((rel, "ID COLUMN IN DATA FILE", ",".join(id_cols), ""))
    # (c) names mentioned
    names = [n for n in ("BENE_ID", "CLM_ID", "PDE_ID") if n in text]
    if names and not found and not (ext in DATA and id_cols):
        kind = "column name as a cell value in a data file (metadata)" if ext in DATA else "column name mentioned in code or text"
        rows.append((rel, kind, ",".join(names), ""))
out = pd.DataFrame(rows, columns=["file", "finding", "ids", "detail"])
out.to_csv(root / "qc/id_scan_report.csv", index=False)
print(f"files scanned: {len(tracked)} tracked/staged ({int((out.finding.str.startswith('binary')).sum())} binary not text-scanned)")
print(out.groupby("finding").size().to_string())
print("\nID VALUE hits:", hits_values or "none"); print("ID COLUMN hits (data files):", hits_cols or "none")
meta = out[out.finding.str.startswith("column name as a cell value")]
if len(meta): print("\nmetadata files that list field names as values (not identifiers):", meta.file.tolist())
sys.exit(1 if (hits_values or hits_cols or hits_abs) else 0)
