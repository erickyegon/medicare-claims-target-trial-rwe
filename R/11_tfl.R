# Step 11: tables, figures and listings (protocol Section 15) -> output/tfl/. Every output carries a footnote naming the program, the dataset
# version and "synthetic data, not inferential"; output/tfl/provenance.csv lists them. Inputs are the aggregate CSVs of earlier steps
# (plus the git-ignored database for T3 and F3 only, which need person-level propensity scores).
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(tidyr); library(readr); library(ggplot2); library(knitr); library(stringr)})
source(file.path(.root, "R", "format_tables.R"))
OUT <- file.path(PROJ_ROOT, "output", "tfl"); dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
S <- function(...) read_csv(file.path(PROJ_ROOT, ...), col_types = cols(), progress = FALSE)
DATASET_VERSION <- trimws(readLines(file.path(PROJ_ROOT, "qc", "dataset_version.txt"))[1])
prov <- list()
foot <- function(program, inputs) sprintf("Program: R/11_tfl.R (inputs from %s). Dataset version: %s (CMS synthetic Medicare files, downloaded 2026-10-20). Synthetic data, not inferential.", inputs, DATASET_VERSION)

# Writes a table as CSV and as a self-contained HTML fragment with the footnote
save_table <- function(id, title, df, program, inputs, note = NULL) {
  fn <- foot(program, inputs); write_csv(df, file.path(OUT, paste0(id, ".csv")), na = "")   # CSV: raw numbers, blank missing values
  html <- c(sprintf("<h3>%s. %s</h3>", id, title), kable(format_table(df), format = "html", align = table_align(df)), if (!is.null(note)) sprintf("<p><em>%s</em></p>", note), sprintf("<p><small>%s</small></p>", fn))
  writeLines(html, file.path(OUT, paste0(id, ".html")))
  prov[[id]] <<- tibble::tibble(id = id, title = title, file = paste0(id, ".csv / .html"), source_program = program, inputs = inputs, dataset_version = DATASET_VERSION)
}
save_figure <- function(id, title, plot, program, inputs, width = 7, height = 4.5) {
  p <- plot + labs(caption = str_wrap(foot(program, inputs), 110)) + theme(plot.caption = element_text(size = 6, hjust = 0))
  ggsave(file.path(OUT, paste0(id, ".png")), p, width = width, height = height, dpi = 150)
  prov[[id]] <<- tibble::tibble(id = id, title = title, file = paste0(id, ".png"), source_program = program, inputs = inputs, dataset_version = DATASET_VERSION)
}
pct <- function(x, d = 1) sprintf("%.*f", d, 100 * x)
ci_str <- function(e, lo, hi, scale = 100, d = 1) sprintf("%.*f (%.*f to %.*f)", d, scale * e, d, scale * lo, d, scale * hi)

# ---- T1 attrition -------------------------------------------------------------------------------------------------------
att <- S("qc", "cohort", "attrition.csv")
save_table("T1", "Cohort attrition", att %>% transmute(Step = step, Criterion = description, Episodes = n_episodes, Persons = n_persons, `Persons removed` = persons_removed), "R/06_cohort.R", "qc/cohort/attrition.csv")

# ---- T2 feasibility ------------------------------------------------------------------------------------------------------
fx <- S("qc", "feasibility_facts.csv"); coh <- S("qc", "cohort", "attrition.csv"); arms <- S("qc", "cohort", "arm_sizes.csv"); sc <- S("qc", "cohort", "sensitivity_cohorts.csv")
t2 <- bind_rows(fx %>% transmute(Section = "Data facts and nulls", Item = item, Value = ifelse(is.na(value), NA_character_, formatC(value, format = "d", big.mark = ",")), `Share of total` = share_pct, Consequence = note),
                tibble::tibble(Section = "Hypertension cohort", Item = c("people in the final cohort", "ACE inhibitor / thiazide", "people removed by the hypertension-diagnosis step"),
                               Value = c(formatC(att$n_persons[att$step == 10], format = "d", big.mark = ","), paste(arms$n[arms$arm == "ACEI"], "/", arms$n[arms$arm == "THIAZIDE"]), formatC(att$persons_removed[att$step == 5], format = "d", big.mark = ",")), `Share of total` = NA_real_, Consequence = "see T1"))
save_table("T2", "Feasibility: data facts, nulls and the hypertension cohort", t2, "R/10_manifest_facts.R, R/06_cohort.R", "qc/feasibility_facts.csv, qc/cohort/")

# ---- T3 baseline by arm with SMDs ------------------------------------------------------------------------------------------
bal <- S("qc", "analysis", "balance_smd.csv"); pc <- S("qc", "analysis", "primary_counts.csv")
f3 <- function(x) sprintf("%.3f", x)
t3 <- bal %>% transmute(Covariate = covariate, `ACE inhibitor (unweighted)` = f3(mean_acei), `Thiazide (unweighted)` = f3(mean_thiazide), `SMD before weighting` = f3(smd_unweighted),
                        `ACE inhibitor (weighted)` = f3(wmean_acei), `Thiazide (weighted)` = f3(wmean_thiazide), `SMD after weighting` = f3(smd_weighted))
cm <- function(x) formatC(x, format = "f", digits = 1, big.mark = ",")
t3 <- bind_rows(tibble::tibble(Covariate = "N (weighted N)", `ACE inhibitor (unweighted)` = formatC(pc$n[pc$arm == "ACEI"], format = "d", big.mark = ","), `Thiazide (unweighted)` = formatC(pc$n[pc$arm == "THIAZIDE"], format = "d", big.mark = ","),
                               `ACE inhibitor (weighted)` = cm(pc$weighted_n[pc$arm == "ACEI"]), `Thiazide (weighted)` = cm(pc$weighted_n[pc$arm == "THIAZIDE"])), t3)
save_table("T3", "Baseline characteristics by arm before and after IPTW, with standardized mean differences", t3, "R/09_analysis.R", "qc/analysis/balance_smd.csv",
           note = "Means of model-matrix columns: proportions for indicators, means for age, visit days and counts. Heart failure and dementia are too rare for the propensity model (see A-011).")

# ---- T4 treatment patterns ---------------------------------------------------------------------------------------------------
tc <- S("qc", "cohort", "timing_counts.csv"); cif <- S("qc", "cohort", "timing_cif.csv")
t4a <- tc %>% transmute(Arm = arm, N = n, `Index days supply (median)` = idx_days_supply_median, `Add-on` = n_addon, Switch = n_switch, Discontinued = n_discontinued, `Censored before any event` = n_censored_before_any,
                        `Median days to add-on` = median_days_addon, `Median days to switch` = median_days_switch, `Median days to discontinuation` = median_days_discontinuation)
t4b <- cif %>% transmute(Arm = arm, Day = day, `Add-on (%)` = cum_inc_pct_addon, `Switch (%)` = cum_inc_pct_switch, `Discontinuation (%)` = cum_inc_pct_discontinuation)
save_table("T4", "Treatment patterns: days supply and time to add-on, switch and discontinuation (first event; descriptive)", bind_rows(t4a %>% mutate(across(everything(), as.character)) %>% mutate(Part = "A: counts and medians", .before = 1),
           t4b %>% mutate(across(everything(), as.character)) %>% mutate(Part = "B: cumulative incidence by day", .before = 1)), "R/07_followup.R", "qc/cohort/timing_counts.csv, timing_cif.csv",
           note = "Discontinuation = no refill within 30 days after the end of the days supply; it does not censor any analysis (A-007).")

# ---- T5 risks ---------------------------------------------------------------------------------------------------------------------
pr <- S("qc", "analysis", "primary_results.csv"); ev <- S("qc", "analysis", "evalue.csv")
w <- pr %>% pivot_wider(names_from = quantity, values_from = c(estimate, lo, hi))
t5 <- w %>% transmute(Method = method, Horizon = paste(horizon, "days"), `ACE inhibitor risk, % (95% CI)` = ci_str(estimate_risk_acei, lo_risk_acei, hi_risk_acei),
                      `Thiazide risk, % (95% CI)` = ci_str(estimate_risk_thiazide, lo_risk_thiazide, hi_risk_thiazide), `Risk difference, percentage points (95% CI)` = ci_str(estimate_rd, lo_rd, hi_rd),
                      `Risk ratio (95% CI)` = ci_str(estimate_rr, lo_rr, hi_rr, scale = 1, d = 2)) %>% arrange(desc(Method), desc(Horizon))
save_table("T5", "All-cause hospitalization, intention-to-treat: 365-day (primary) and 30-day (secondary) risks, risk difference and risk ratio", t5, "R/09_analysis.R", "qc/analysis/primary_results.csv",
           note = sprintf("IPTW-weighted; 95%% percentile bootstrap intervals (500 resamples of individuals, propensity score refitted). E-value for the 365-day risk ratio: %.2f (confidence limit: %.2f). Events: ACE inhibitor %d, thiazide %d (365 days).",
                          ev$value[1], ev$value[2], pc$hosp_365_events_unweighted[pc$arm == "ACEI"], pc$hosp_365_events_unweighted[pc$arm == "THIAZIDE"]))

# ---- T6 sensitivity -----------------------------------------------------------------------------------------------------------------
se <- S("qc", "analysis", "sensitivity_results.csv")
t6 <- se %>% transmute(Analysis = analysis, N = n, `Events (ACE inhibitor / thiazide)` = paste(events_acei, "/", events_thiazide), `ACE inhibitor risk, %` = pct(km365_risk_acei), `Thiazide risk, %` = pct(km365_risk_thiazide),
                       `RD, points (95% CI)` = ci_str(km365_rd, km365_rd_lo, km365_rd_hi), `RR (95% CI)` = ci_str(km365_rr, km365_rr_lo, km365_rr_hi, 1, 2), Note = note)
save_table("T6", "Sensitivity analyses: 365-day hospitalization (weighted Kaplan-Meier)", t6, "R/09_analysis.R", "qc/analysis/sensitivity_results.csv")

# ---- T7 negative control (descriptive) -------------------------------------------------------------------------------------------
nc <- S("qc", "analysis", "negative_control_descriptive.csv")
save_table("T7", "Negative control outcome: hip or femur fracture within 365 days (counts and person-time only; no model, A-006)", nc %>% transmute(Arm = arm, N = n, Events = fracture_365_itt, `Person-years` = py_fracture, `Events per 1,000 person-years` = round(1000 * fracture_365_itt / py_fracture, 1)),
           "R/07_followup.R, R/09_analysis.R", "qc/analysis/negative_control_descriptive.csv", note = "Counts below 11 are flagged and must not be interpreted.")

# ---- F1 design diagram --------------------------------------------------------------------------------------------------------------------
seg <- tibble::tibble(label = c("Baseline: covariates, new-user check\n(days -365 to -1)", "Index date\n(first fill of ACE inhibitor\nor thiazide)", "ITT follow-up: days 1 to 365\n(ends at loss of A/B/D, 2023-03-31, or day 365)"),
                      x0 = c(-365, 0, 1), x1 = c(-1, 0.5, 365), y = c(2, 2, 2))
f1 <- ggplot() + geom_rect(data = seg[c(1, 3), ], aes(xmin = x0, xmax = x1, ymin = 1.4, ymax = 2.6, fill = label), alpha = 0.35) + geom_vline(xintercept = 0, linewidth = 1) +
  geom_text(data = seg[c(1, 3), ], aes(x = (x0 + x1) / 2, y = 2, label = label), size = 3) +
  geom_label(aes(x = 0, y = 3.0, label = "Index date: first fill of ACE inhibitor or thiazide
(eligibility diagnosis window: days -365 to 0)"), size = 3, label.size = 0) +
  annotate("text", x = -183, y = 1.05, label = "New user: no antihypertensive fill in days -365 to -1
No other antihypertensive class on the index date", size = 2.8) +
  scale_x_continuous(breaks = c(-365, 0, 365), name = "Days relative to index") + scale_y_continuous(limits = c(0.7, 3.3)) + theme_minimal() + theme(legend.position = "none", axis.text.y = element_blank(), axis.title.y = element_blank(), panel.grid = element_blank())
save_figure("F1", "Study design diagram", f1, "R/11_tfl.R", "protocol v0.4 Sections 5 and 9")

# ---- F2 love plot, F3 PS distributions, F4 cumulative incidence -------------------------------------------------------------------------
love <- bal %>% mutate(covariate = factor(covariate, levels = covariate[order(abs(smd_unweighted))])) %>% pivot_longer(c(smd_unweighted, smd_weighted), names_to = "sample", values_to = "smd") %>%
  mutate(sample = ifelse(sample == "smd_unweighted", "before weighting", "after IPTW"))
save_figure("F2", "Love plot of covariate balance", ggplot(love, aes(abs(smd), covariate, colour = sample)) + geom_point() + geom_vline(xintercept = 0.1, linetype = 2) + labs(x = "|Standardized mean difference|", y = NULL, colour = NULL) + theme_minimal(),
            "R/09_analysis.R", "qc/analysis/balance_smd.csv", height = 6.5)
con <- connect_db(read_only = TRUE); psd <- dbGetQuery(con, "SELECT arm_acei, ps FROM analysis_primary"); dbDisconnect(con, shutdown = TRUE)
save_figure("F3", "Propensity score distributions by arm", ggplot(psd %>% mutate(arm = ifelse(arm_acei == 1, "ACE inhibitor", "Thiazide")), aes(ps, fill = arm)) + geom_density(alpha = 0.4) +
              labs(x = "Propensity score (probability of ACE inhibitor)", y = "Density", fill = NULL) + theme_minimal(), "R/09_analysis.R", "database table analysis_primary (person-level, not published)")
cv <- S("qc", "analysis", "cumulative_incidence_curves.csv") %>% mutate(arm = ifelse(arm == "ACEI", "ACE inhibitor", "Thiazide"))
save_figure("F4", "IPTW-weighted cumulative incidence of hospitalization", ggplot(cv, aes(day, 100 * cuminc, colour = arm, fill = arm)) + geom_ribbon(aes(ymin = 100 * lo, ymax = 100 * hi), alpha = 0.15, colour = NA) + geom_step() +
              labs(x = "Days since index", y = "Cumulative incidence (%)", colour = NULL, fill = NULL, subtitle = "Shaded bands: 95% bootstrap intervals by day") + theme_minimal(), "R/09_analysis.R", "qc/analysis/cumulative_incidence_curves.csv")

# ---- L1 code lists ------------------------------------------------------------------------------------------------------------------------------
cl <- list.files(file.path(PROJ_ROOT, "codelists"), pattern = "\\.csv$", full.names = TRUE)
l1_sum <- bind_rows(lapply(cl, function(f) { x <- read_csv(f, col_types = cols(.default = "c"), progress = FALSE); tibble::tibble(`Code list` = basename(f), Rows = nrow(x), Columns = paste(names(x), collapse = ", "),
                   Source = if ("source" %in% names(x)) paste(head(unique(x$source), 2), collapse = " | ") else if ("source_ssa_code" %in% names(x)) x$source_ssa_code[1] else "") }))
save_table("L1", "Code lists used (counts, columns and sources; full lists are in codelists/)", l1_sum, "R/03_codelists.R, R/06_codelists_ahtn.R, codelists/build/*.py", "codelists/*.csv")
write_csv(bind_rows(lapply(c("icd10_bronchitis.csv", "icd10_exclusions.csv", "icd10_hypertension.csv", "antihypertensive_ingredients.csv", "revenue_center_ed.csv", "ssa_state_region.csv"), function(f) {
  x <- read_csv(file.path(PROJ_ROOT, "codelists", f), col_types = cols(.default = "c"), progress = FALSE); x$list <- f; x })) %>% select(list, everything()), file.path(OUT, "L1_full_listing_small_lists.csv"))

# ---- L2 variable derivation listing ---------------------------------------------------------------------------------------------------------------
l2 <- tibble::tribble(
  ~Variable, ~Definition, ~Window, ~Source, ~Program,
  "arm", "Class of the study drug filled on the index date: ACE inhibitor (ATC C09AA) or thiazide / thiazide-like (C03AA, C03BA)", "index date", "PDE via RxNorm NDC map", "sql/index_events.sql",
  "index date", "First fill (on or after 2016-03-01) meeting every criterion of Section 5, one episode per person", "-", "PDE, enrollment, claims", "R/06_cohort.R",
  "new user", "No fill of any antihypertensive class", "days -365 to -1", "PDE", "sql/index_events.sql",
  "continuous A+B+D", "Part A, B and D present in every month from the month of day -365 through the index month", "days -365 to 0", "beneficiary files", "sql/enrollment_spans.sql",
  "hypertension diagnosis (eligibility)", "ICD-10-CM I10-I16 on any carrier, outpatient or inpatient claim", "days -365 to 0", "claims", "sql/index_events.sql",
  "hospitalization (outcome)", "First inpatient admission date", "days 1 to 365 (1 to 30 for the secondary outcome)", "inpatient file", "sql/followup.sql",
  "ITT follow-up end", "Earliest of day 365, 2023-03-31, and end of the A+B+D span containing the index month", "-", "beneficiary files", "R/07_followup.R",
  "femur fracture (negative control)", "ICD-10-CM S72 initial-encounter codes, with and without the 7th character", "days 1 to 365", "claims", "R/03_codelists.R",
  "age", "Completed years at the index date", "index date", "beneficiary files", "sql/baseline.sql",
  "sex, race, region, index year, index quarter", "From the beneficiary file for the index year (earliest row if missing); region via ssa_state_region.csv; index month grouped to quarter", "index", "beneficiary files", "sql/baseline.sql, R/08_baseline.R",
  "COPD, asthma, ischemic heart disease, diabetes, chronic kidney disease, cancer (dementia, heart failure not modelled)", "At least one claim with a CCW code for the condition (A-003)", "days -365 to -1", "claims", "sql/baseline.sql",
  "visit days", "Distinct dates of carrier or outpatient claims that carry a diagnosis; modelled as log(1 + days)", "days -365 to -1", "carrier, outpatient", "sql/baseline.sql",
  "any baseline hospitalization", "At least one inpatient admission", "days -365 to -1", "inpatient", "sql/baseline.sql",
  "distinct drugs, distinct drug classes", "Distinct RxNorm drugs and ATC level-4 classes among fills with an RxNorm drug concept", "days -365 to -1", "PDE via RxNorm / RxClass", "sql/baseline.sql",
  "propensity score and weights", "Logistic model on the covariates above; stabilized ATE weights truncated at the 1st and 99th percentile", "-", "analysis data", "R/09_analysis_functions.R",
  "add-on / switch / discontinuation", "First fill of the other study drug (add-on if the index class still has supply, else switch); discontinuation = no refill within 30 days after the end of supply", "after index", "PDE", "R/07_followup.R")
save_table("L2", "Variable derivation listing", l2, "R/11_tfl.R", "sql/*.sql, R/*.R")

write_csv(bind_rows(prov), file.path(OUT, "provenance.csv"))
idx <- c("<html><head><meta charset='utf-8'><title>TFL index</title></head><body><h1>Tables, figures and listings</h1><p>Synthetic data, not inferential. Dataset version ", DATASET_VERSION, ".</p><ul>",
         vapply(prov, function(p) sprintf("<li>%s: %s (%s)</li>", p$id, p$title, p$file), ""), "</ul></body></html>")
writeLines(idx, file.path(OUT, "index.html"))
message("TFLs written: ", paste(names(prov), collapse = ", "))
