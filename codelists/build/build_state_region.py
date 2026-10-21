"""Build codelists/ssa_state_region.csv: SSA state code (MBSF STATE_CODE) -> state -> Census region.
Sources (both official, downloaded 2026-10-20):
  data/ref/resdac_ssa_state_code_mbsf.txt   ResDAC / CCW MBSF codebook V1.6 (Feb 2024), 'State Code for beneficiary (SSA code) Code Table'
  data/ref/census_state_geocodes.xlsx       U.S. Census Bureau region and division codes and FIPS codes for states (release May 2021)
Codes that are not a US state or DC (territories, foreign countries) get region 'other'. Carrier-area duplicate codes (67-74, 80) map to the named state."""
import re, csv, pathlib, datetime
import pandas as pd
root = pathlib.Path(__file__).resolve().parents[2]
txt = (root / "data/ref/resdac_ssa_state_code_mbsf.txt").read_text(encoding="utf-8", errors="replace").replace("\r", "")
txt = re.sub(r"Chronic Condition Warehouse.*?\n.*?V 1\.6 \d+\n", "", txt, flags=re.S)           # page-break lines inside the table
txt = txt.replace("Northern \nMarianas", "Northern Marianas")
codes = {}
for line in txt.splitlines():
    m = re.match(r"^(\d\d) = (.+)$", line.strip())
    if m: codes[m.group(1)] = re.sub(r"\s*\(eff\..*\)$", "", m.group(2)).strip()
cen = pd.read_excel(root / "data/ref/census_state_geocodes.xlsx", header=None, dtype=str, skiprows=6)
cen.columns = ["region", "division", "fips", "name"]
REGION = {"1": "Northeast", "2": "Midwest", "3": "South", "4": "West"}
state_region = {r["name"]: REGION[r["region"]] for _, r in cen.iterrows() if r["fips"] != "00" and r["region"] in REGION}
today = datetime.date.today().isoformat()
rows = []
for code, name in sorted(codes.items()):
    rows.append([code, name, state_region.get(name, "other"), "ResDAC CCW MBSF codebook V1.6 (Feb 2024)", "US Census Bureau state geocodes (May 2021)", today])
with open(root / "codelists/ssa_state_region.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f); w.writerow(["ssa_code", "state", "census_region", "source_ssa_code", "source_region", "download_date"]); w.writerows(rows)
df = pd.DataFrame(rows, columns=["ssa_code", "state", "census_region", "a", "b", "c"])
print(len(df), "codes;", df.census_region.value_counts().to_dict())
print("states (50 + DC) assigned:", sum(df.census_region != "other" ) , "| unmatched names among code 01-53 states:", [n for c, n, r, *_ in rows if c <= "53" and r == "other"])
