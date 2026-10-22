import sys, pandas as pd, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
repo = sys.argv[1]
ci = pd.read_csv(f"{repo}/qc/analysis/cumulative_incidence_curves.csv")
pr = pd.read_csv(f"{repo}/qc/analysis/primary_results.csv")
g = lambda q, c="estimate": pr.loc[(pr.method=="weighted KM")&(pr.horizon==365)&(pr.quantity==q), c].item()
rr, lo, hi = g("rr"), g("rr","lo"), g("rr","hi")
ra, rt = g("risk_acei")*100, g("risk_thiazide")*100
INK, INK2, MUTED, BG = "#1f1f1e", "#52524d", "#7a7a73", "#fbfbf9"
COL = {"ACEI": "#2a78d6", "THIAZIDE": "#eb6834"}
LAB = {"ACEI": "ACE inhibitor", "THIAZIDE": "Thiazide"}
plt.rcParams.update({"font.family": "DejaVu Sans"})

def card(w, h, out):
    dpi = 100
    fig = plt.figure(figsize=(w/dpi, h/dpi), dpi=dpi, facecolor=BG)
    s = h/627
    # left text block
    fig.text(0.045, 0.86, "Target trial emulation on", fontsize=19*s, color=INK2)
    fig.text(0.045, 0.785, "Medicare claims", fontsize=34*s, color=INK, weight="bold")
    fig.text(0.045, 0.715, "ACE inhibitor vs thiazide, new users aged 65+", fontsize=14*s, color=INK2)
    fig.text(0.045, 0.53, "365-day hospitalization (IPTW)", fontsize=13*s, color=MUTED)
    fig.text(0.045, 0.445, f"RR {rr:.2f}", fontsize=40*s, color=INK, weight="bold")
    fig.text(0.045, 0.385, f"95% CI {lo:.2f} to {hi:.2f}: includes no difference", fontsize=13*s, color=INK2)
    for i, t in enumerate(["Propensity score weighting, censoring weights, bootstrap",
                           "Cohort reconciled independently in R, Python and SAS"]):
        fig.text(0.045, 0.255 - i*0.055, t, fontsize=12.5*s, color=INK2)
    fig.text(0.045, 0.065, "Synthetic CMS data. Methods demonstration, not evidence about either drug.",
             fontsize=11.5*s, color=MUTED, style="italic")
    # chart
    ax = fig.add_axes([0.565, 0.2, 0.30, 0.62], facecolor=BG)
    for arm in ["ACEI", "THIAZIDE"]:
        d = ci[ci.arm == arm].sort_values("day")
        ax.fill_between(d.day, d.lo*100, d.hi*100, step="post", color=COL[arm], alpha=0.13, lw=0)
        ax.step(d.day, d.cuminc*100, where="post", color=COL[arm], lw=2.2)
        last = d.iloc[-1]
        ax.text(372, last.cuminc*100 + (2.0 if arm == "ACEI" else -2.0), f"{LAB[arm]}\n{last.cuminc*100:.1f}%",
                color=INK, fontsize=12*s, va="center", ha="left")
    ax.set_xlim(0, 365); ax.set_ylim(0, 28)
    ax.set_xticks([0, 90, 180, 270, 365]); ax.set_yticks([0, 10, 20])
    ax.set_yticklabels(["0%", "10%", "20%"])
    ax.tick_params(colors=MUTED, labelsize=11*s, length=0)
    for sp in ["top", "right", "left"]: ax.spines[sp].set_visible(False)
    ax.spines["bottom"].set_color("#cfcfc8")
    ax.grid(axis="y", color="#e6e6e0", lw=0.8); ax.set_axisbelow(True)
    ax.set_xlabel("Days since first fill", color=MUTED, fontsize=11.5*s)
    fig.text(0.565, 0.86, "Weighted cumulative incidence, 95% bootstrap bands", fontsize=12*s, color=INK2)
    fig.savefig(out, dpi=dpi, facecolor=BG); plt.close(fig)

card(1200, 627, "social_card_1200x627.png")
card(1280, 640, "github_social_preview_1280x640.png")
print(rr, lo, hi, ra, rt)
