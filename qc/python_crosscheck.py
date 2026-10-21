"""Independent re-derivation of the hypertension cohort attrition table (protocol v0.4) in pandas (a second check besides the SAS program).
Deliberately different from the R/SQL code: enrollment is checked by counting A+B+D months in the look-back range (no spans),
and every criterion is evaluated with per-person Python loops. Reads the ingested raw tables and the code lists, never the R cohort tables.
Run from the project root:  python qc/python_crosscheck.py        (writes qc/cohort/python_vs_r_attrition.csv)"""
import duckdb, pandas as pd, numpy as np, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
con = duckdb.connect(str(root / "data/medicare.duckdb"), read_only=True)
D = lambda s: np.datetime64(s)

# ---- code lists ----
ndc = pd.read_csv(root / "codelists/ndc_antihypertensive.csv", dtype=str)[["ndc11", "ahtn_class"]]
htn_codes = tuple(pd.read_csv(root / "codelists/icd10_hypertension.csv", dtype=str)["icd10_code"])

# ---- demographics and monthly A+B+D months (set of year*12+month per person) ----
bene = con.execute("SELECT * FROM bene").df()
birth = bene.groupby("BENE_ID")["BENE_BIRTH_DT"].min()
abd = {}
for m in range(1, 13):
    b = bene[f"MDCR_ENTLMT_BUYIN_IND_{m:02d}"].isin(["1", "3", "A", "C"]) & bene[f"MDCR_ENTLMT_BUYIN_IND_{m:02d}"].isin(["2", "3", "B", "C"]) | False
    a_ = bene[f"MDCR_ENTLMT_BUYIN_IND_{m:02d}"].isin(["1", "3", "A", "C"])
    b_ = bene[f"MDCR_ENTLMT_BUYIN_IND_{m:02d}"].isin(["2", "3", "B", "C"])
    d_ = bene[f"PTD_CNTRCT_ID_{m:02d}"].notna()
    ok = a_ & b_ & d_
    for bid, yr in zip(bene.loc[ok, "BENE_ID"], bene.loc[ok, "BENE_ENROLLMT_REF_YR"].astype(int)):
        abd.setdefault(bid, set()).add(yr * 12 + m)

# ---- fills, hypertension diagnosis dates, hospice, inpatient stays ----
pde = con.execute("SELECT BENE_ID, SRVC_DT AS dt, PROD_SRVC_ID AS ndc11 FROM pde").df().merge(ndc, on="ndc11")
pde["dt"] = pd.to_datetime(pde["dt"])
codes = ",".join(f"'{c}'" for c in htn_codes)
def dx_dates(table, k):
    cols = ["PRNCPAL_DGNS_CD"] + [f"ICD_DGNS_CD{i}" for i in range(1, k + 1)]
    where = " OR ".join(f"{c} IN ({codes})" for c in cols)
    return con.execute(f"SELECT DISTINCT BENE_ID, CLM_FROM_DT AS dt FROM {table} WHERE {where}").df()
dx = pd.concat([dx_dates("carrier", 12), dx_dates("outpatient", 25), dx_dates("inpatient", 25)]).drop_duplicates()
dx["dt"] = pd.to_datetime(dx["dt"])
hosp = con.execute("SELECT DISTINCT BENE_ID, CLM_FROM_DT AS f, CLM_THRU_DT AS t FROM hospice").df()
stay = con.execute("SELECT DISTINCT BENE_ID, CLM_ADMSN_DT AS a, CLM_THRU_DT AS t FROM inpatient WHERE CLM_ADMSN_DT IS NOT NULL").df()
by = lambda df: {k: g for k, g in df.groupby("BENE_ID")}
pde_by, dx_by, hosp_by, stay_by = by(pde), by(dx), by(hosp), by(stay)

START = pd.Timestamp("2016-03-01")
rows = []   # one row per candidate (person, study-drug fill date)
for bid, g in pde_by.items():
    g = g.sort_values("dt")
    study = g[g.ahtn_class.isin(["ACEI", "THIAZIDE"]) & (g.dt >= START)]
    for idx, s in study.groupby("dt"):
        rows.append((bid, idx, bool((s.ahtn_class == "ACEI").any()), bool((s.ahtn_class == "THIAZIDE").any())))
cand = pd.DataFrame(rows, columns=["BENE_ID", "idx", "acei", "thi"])
n_cand_e, n_cand_p = len(cand), cand.BENE_ID.nunique()

def newuser(r):
    g = pde_by[r.BENE_ID]
    return not ((g.dt >= r.idx - pd.Timedelta(days=365)) & (g.dt <= r.idx - pd.Timedelta(days=1))).any()
cand = cand[cand.apply(newuser, axis=1)].copy()
steps = [("Beneficiaries", None, bene.BENE_ID.nunique()), ("Candidates", n_cand_e, n_cand_p), ("New user", len(cand), cand.BENE_ID.nunique())]

def age_ok(r):
    b = pd.Timestamp(birth[r.BENE_ID]); return r.idx >= b + pd.DateOffset(years=65)
def enroll_ok(r):
    lo = (r.idx - pd.Timedelta(days=365)); lo_mi = lo.year * 12 + lo.month; hi_mi = r.idx.year * 12 + r.idx.month
    have = abd.get(r.BENE_ID, set())
    return all(mi in have for mi in range(lo_mi, hi_mi + 1))
def htn_ok(r):
    g = dx_by.get(r.BENE_ID)
    return g is not None and ((g.dt >= r.idx - pd.Timedelta(days=365)) & (g.dt <= r.idx)).any()     # A-009: days -365 to 0
def both_ok(r): return not (r.acei and r.thi)
def costart_ok(r):                                                                                   # A-010: no other antihypertensive class on the index date
    g = pde_by[r.BENE_ID]
    return not ((g.dt == r.idx) & (~g.ahtn_class.isin(["ACEI", "THIAZIDE"]))).any()
def hospice_ok(r):
    g = hosp_by.get(r.BENE_ID)
    return g is None or not ((pd.to_datetime(g.f) <= r.idx - pd.Timedelta(days=1)) & (pd.to_datetime(g.t) >= r.idx - pd.Timedelta(days=365))).any()
def inpt_ok(r):
    g = stay_by.get(r.BENE_ID)
    return g is None or not ((pd.to_datetime(g.a) <= r.idx) & (pd.to_datetime(g.t) >= r.idx)).any()
for step, label, fn in [(3, "Age", age_ok), (4, "Enrollment", enroll_ok), (5, "Hypertension dx", htn_ok), (6, "Not both", both_ok), (7, "No other class same day", costart_ok), (8, "No hospice", hospice_ok), (9, "No inpatient overlap", inpt_ok)]:
    cand = cand[cand.apply(fn, axis=1)]
    steps.append((label, len(cand), cand.BENE_ID.nunique()))
final = cand.sort_values("idx").groupby("BENE_ID").head(1)
steps.append(("Final cohort", len(final), final.BENE_ID.nunique()))
py = pd.DataFrame(steps, columns=["step_label", "py_episodes", "py_persons"]); py["step"] = range(len(py))
r = pd.read_csv(root / "qc/cohort/attrition.csv")[["step", "n_episodes", "n_persons"]].rename(columns={"n_episodes": "r_episodes", "n_persons": "r_persons"})
out = r.merge(py, on="step")
out["result"] = np.where((out.r_persons == out.py_persons) & ((out.r_episodes == out.py_episodes) | (out.r_episodes.isna() & out.py_episodes.isna())), "PASS", "FAIL")
final["arm"] = np.where(final.acei, "ACEI", "THIAZIDE")
arms = final.arm.value_counts().to_dict()
out.to_csv(root / "qc/cohort/python_vs_r_attrition.csv", index=False)
print(out.to_string(index=False)); print("python arms:", arms)
ra = pd.read_csv(root / "qc/cohort/arm_sizes.csv").set_index("arm").n.to_dict()
print("arm sizes match R:", arms == ra)

# ---- follow-up (A-008): ITT end = min(day 365, 2023-03-31, end of the A+B+D run that contains the index month); hospitalization = first admission on days 1 to end ----
END_OF_DATA = pd.Timestamp("2023-03-31")
def run_end(bid, idx):
    have = abd.get(bid, set()); mi = idx.year * 12 + idx.month
    while (mi + 1) in have: mi += 1
    y, m = divmod(mi - 1, 12); nxt = pd.Timestamp(year=y + (1 if m == 11 else 0), month=(m + 1) % 12 + 1, day=1)
    return nxt - pd.Timedelta(days=1)
final = final.copy()
final["itt_end"] = [min(r.idx + pd.Timedelta(days=365), END_OF_DATA, run_end(r.BENE_ID, r.idx)) for r in final.itertuples()]
def hosp(r):
    g = stay_by.get(r.BENE_ID)
    if g is None: return False
    a = pd.to_datetime(g.a); return ((a >= r.idx + pd.Timedelta(days=1)) & (a <= r.itt_end)).any()
final["hosp"] = final.apply(hosp, axis=1); final["full365"] = final.itt_end == final.idx + pd.Timedelta(days=365)
fu = final.groupby("arm").agg(n=("BENE_ID", "size"), py_n_full_365=("full365", "sum"), py_hosp_365_itt=("hosp", "sum")).reset_index()
rc = pd.read_csv(root / "qc/cohort/crude_events.csv")[["arm", "n_full_365", "hosp_365_itt"]]
fcmp = fu.merge(rc, on="arm"); fcmp["result"] = np.where((fcmp.py_n_full_365 == fcmp.n_full_365) & (fcmp.py_hosp_365_itt == fcmp.hosp_365_itt), "PASS", "FAIL")
fcmp.to_csv(root / "qc/cohort/python_vs_r_followup.csv", index=False)
print(fcmp.to_string(index=False))
sys.exit(0 if (out.result == "PASS").all() and arms == ra and (fcmp.result == "PASS").all() else 1)
