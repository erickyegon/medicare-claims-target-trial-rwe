# Step 06: hypertension cohort (protocol v0.4 Section 5): index candidates, sequential criteria, attrition table, arms,
# and the sensitivity cohorts (A-009, A-010). build_cohort(con) works on any connection holding the canonical tables,
# so the unit tests can run it on hand-built data.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr)})

# Criteria in protocol order: (step number, flag column in cand_flags, label). Criterion 1 (new user) is applied inside index_events.sql.
COHORT_STEPS <- tibble::tribble(
  ~step, ~flag, ~label,
  3, "f_age",       "Age 65 or older on the index date",
  4, "f_enroll",    "Continuous Part A+B+D from the month of day -365 through the index month",
  5, "f_htn",       "Hypertension diagnosis (I10-I16) in days -365 to 0 (A-009)",
  6, "f_notboth",   "Not both study drugs filled on the index date",
  7, "f_nocostart", "No other antihypertensive class filled on the index date (A-010)",
  8, "f_nohospice", "No hospice claim in days -365 to -1",
  9, "f_noinpt",    "No inpatient stay overlapping the index date")
PRIMARY_FLAGS <- COHORT_STEPS$flag

# Registers the code-list tables the SQL expects. `ndc_ahtn`: ndc11 + ahtn_class; `ndc_resolved`: NDCs with an RxNorm record (measure 1); `icd_htn`: codes.
register_cohort_inputs <- function(con, ndc_ahtn, ndc_resolved, icd_htn) {
  duckdb::duckdb_register(con, "ndc_ahtn", ndc_ahtn); duckdb::duckdb_register(con, "ndc_resolved", ndc_resolved); duckdb::duckdb_register(con, "icd_htn", icd_htn)
}

count_persons <- function(con, from_where) dbGetQuery(con, sprintf("SELECT count(*) AS e, count(DISTINCT BENE_ID) AS p FROM %s", from_where))

# One row per beneficiary: the first candidate that satisfies every predicate in `where`. Columns: arm, costart (another class started the
# same day), no_rxnorm_baseline (>= 1 baseline fill with no RxNorm record), htn_index_only (diagnosis only on the index date, not in days -365 to -1).
make_cohort <- function(con, name, where) {
  dbExecute(con, sprintf("CREATE OR REPLACE TABLE %s AS
    SELECT c.BENE_ID, c.idx, CASE WHEN c.acei THEN 'ACEI' ELSE 'THIAZIDE' END AS arm, NOT c.f_nocostart AS costart,
           c.info_no_rxnorm_baseline_fill AS no_rxnorm_baseline, NOT c.f_htn_strict AS htn_index_only
    FROM cand_flags c JOIN (SELECT BENE_ID, min(idx) AS idx FROM cand_flags WHERE %s GROUP BY BENE_ID) m ON m.BENE_ID = c.BENE_ID AND m.idx = c.idx", name, where))
}
arm_counts <- function(con, tbl) {
  x <- dbGetQuery(con, sprintf("SELECT arm, count(*) AS n FROM %s GROUP BY 1", tbl))
  v <- c(ACEI = 0, THIAZIDE = 0); v[x$arm] <- x$n; v
}

build_cohort <- function(con, log = TRUE) {
  run_sql_file(con, "index_events.sql")
  n_bene <- dbGetQuery(con, "SELECT count(DISTINCT BENE_ID) FROM demo")[[1]]
  sd <- count_persons(con, "study_day"); nu <- count_persons(con, "cand_nu")
  att <- tibble::tibble(step = c(0, 1, 2), description = c("Beneficiaries in the beneficiary files", "Fill of an ACE inhibitor or thiazide/thiazide-like diuretic on/after 2016-03-01 (candidate index dates)",
                                                           "New user: no antihypertensive fill in days -365 to -1"),
                        n_episodes = c(NA, sd$e, nu$e), n_persons = c(n_bene, sd$p, nu$p))
  pred <- character(0)
  for (i in seq_len(nrow(COHORT_STEPS))) {
    pred <- c(pred, COHORT_STEPS$flag[i]); cnt <- count_persons(con, sprintf("cand_flags WHERE %s", paste(pred, collapse = " AND ")))
    att <- bind_rows(att, tibble::tibble(step = COHORT_STEPS$step[i], description = COHORT_STEPS$label[i], n_episodes = cnt$e, n_persons = cnt$p))
  }
  make_cohort(con, "htn_cohort", paste(PRIMARY_FLAGS, collapse = " AND "))
  fin <- count_persons(con, "htn_cohort")
  att <- bind_rows(att, tibble::tibble(step = 10, description = "First qualifying episode per beneficiary (final cohort)", n_episodes = fin$p, n_persons = fin$p))
  att <- att %>% mutate(persons_removed = lag(n_persons) - n_persons, episodes_removed = lag(n_episodes) - n_episodes)
  arms <- dbGetQuery(con, "SELECT arm, count(*) AS n FROM htn_cohort GROUP BY 1 ORDER BY 1")

  # sensitivity cohorts (each re-selects the first qualifying episode under its own rule)
  make_cohort(con, "htn_cohort_costart", paste(setdiff(PRIMARY_FLAGS, "f_nocostart"), collapse = " AND "))                       # A-010 (i): keep co-starters, indicator `costart`
  make_cohort(con, "htn_cohort_strictdx", paste(sub("^f_htn$", "f_htn_strict", PRIMARY_FLAGS), collapse = " AND "))             # A-009: diagnosis in days -365 to -1 only
  make_cohort(con, "htn_cohort_nounid", paste(c(PRIMARY_FLAGS, "NOT info_no_rxnorm_baseline_fill"), collapse = " AND "))             # A-010 (ii): no baseline fill with no RxNorm record
  sens <- bind_rows(lapply(list(c("htn_cohort", "Primary cohort"), c("htn_cohort_costart", "Keep other-class co-starters (indicator covariate)"),
                                c("htn_cohort_strictdx", "Hypertension diagnosis only in days -365 to -1"), c("htn_cohort_nounid", "Exclude any baseline fill with no RxNorm record")),
                           function(z) { a <- arm_counts(con, z[1]); tibble::tibble(cohort = z[2], table = z[1], n_persons = sum(a), ACEI = a[["ACEI"]], THIAZIDE = a[["THIAZIDE"]]) }))
  q1 <- function(s) dbGetQuery(con, s)[[1]]
  info <- tibble::tibble(item = c("Primary cohort members with >= 1 baseline fill with no RxNorm record (removed in the no-RxNorm-record sensitivity cohort)",
                                  "Primary cohort members whose only hypertension diagnosis falls on the index date (removed in the strict-diagnosis sensitivity cohort)",
                                  "Co-starters (another antihypertensive class on the index date) in the keep-co-starters cohort"),
                         n_persons = c(q1("SELECT count(*) FROM htn_cohort WHERE no_rxnorm_baseline"), q1("SELECT count(*) FROM htn_cohort WHERE htn_index_only"), q1("SELECT count(*) FROM htn_cohort_costart WHERE costart")))
  if (log) log_step("06_cohort", sprintf("attrition: %d candidates -> %d new-user -> %d final persons (ACEI %d, THIAZIDE %d)", sd$e, nu$e, fin$p, arms$n[arms$arm == "ACEI"], arms$n[arms$arm == "THIAZIDE"]), sd$e, fin$p)
  list(attrition = att, arms = arms, sensitivity_cohorts = sens, informational = info)
}

# Simple baseline counts by arm (age group at index, sex) - re-derived independently in SAS (sas/cohort_qc.sas)
cohort_baseline_counts <- function(con, cohort = "htn_cohort") {
  x <- dbGetQuery(con, sprintf("SELECT h.arm, date_diff('year', d.birth, h.idx) - (CASE WHEN strftime(h.idx, '%%m%%d') < strftime(d.birth, '%%m%%d') THEN 1 ELSE 0 END) AS age, d.sex
                        FROM %s h JOIN demo d ON d.BENE_ID = h.BENE_ID", cohort))
  x$age_group <- cut(x$age, c(64, 74, 84, Inf), labels = c("65-74", "75-84", "85+")); x$sex <- ifelse(x$sex == "1", "male", ifelse(x$sex == "2", "female", "unknown"))
  bind_rows(x %>% count(arm, level = as.character(age_group)) %>% mutate(variable = "age_group"), x %>% count(arm, level = sex) %>% mutate(variable = "sex")) %>%
    select(arm, variable, level, n) %>% arrange(arm, variable, level)
}

if (sys.nframe() == 0) {
  con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  run_sql_file(con, "canonical.sql")
  ndc_ahtn <- read_csv(file.path(PROJ_ROOT, "codelists", "ndc_antihypertensive.csv"), col_types = cols(.default = "c")) %>% select(ndc11, ahtn_class)
  resolved <- read_csv(file.path(PROJ_ROOT, "codelists", "ndc_resolved.csv"), col_types = cols(.default = "c")) %>% select(ndc11)
  htn <- read_csv(file.path(PROJ_ROOT, "codelists", "icd10_hypertension.csv"), col_types = cols(.default = "c")) %>% transmute(code = icd10_code)
  register_cohort_inputs(con, ndc_ahtn, resolved, htn)
  r <- build_cohort(con)
  out <- file.path(PROJ_ROOT, "qc", "cohort"); dir.create(out, showWarnings = FALSE)
  write_csv(r$attrition, file.path(out, "attrition.csv"), na = "")   # blank, not "NA", so SAS reads the counts as numbers
  write_csv(r$arms, file.path(out, "arm_sizes.csv")); write_csv(cohort_baseline_counts(con), file.path(out, "cohort_baseline_counts.csv"))
  write_csv(r$sensitivity_cohorts, file.path(out, "sensitivity_cohorts.csv")); write_csv(r$informational, file.path(out, "cohort_informational_counts.csv"))
  print(as.data.frame(r$attrition)); print(r$arms); print(as.data.frame(r$sensitivity_cohorts)); print(as.data.frame(r$informational))
}
