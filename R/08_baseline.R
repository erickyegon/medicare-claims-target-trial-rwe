# Step 08: person-level baseline covariate dataset for a hypertension cohort (protocol v0.4 Section 8).
# Covariate window days -365 to -1. Missing demographics get an explicit "unknown" level. Index setting is not used (A-002); ED visits and
# vaccination are not identifiable in these data (no ED revenue/procedure/place-of-service codes, no vaccine codes) and are reported as unavailable.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(readr); library(tidyr)})

CCW_GROUPS <- c("copd", "asthma", "heart_failure", "ischemic_heart_disease", "diabetes", "chronic_kidney_disease", "dementia", "cancer")

# SSA state code -> Census region, from the versioned code list codelists/ssa_state_region.csv (ResDAC/CCW MBSF codebook V1.6 + Census Bureau
# state geocodes; built by codelists/build/build_state_region.py). Territories and foreign codes are "other"; missing codes are "unknown".
ssa_region <- function(state, map_file = file.path(PROJ_ROOT, "codelists", "ssa_state_region.csv")) {
  map <- readr::read_csv(map_file, col_types = readr::cols(.default = "c"), progress = FALSE)
  r <- map$census_region[match(state, map$ssa_code)]
  ifelse(is.na(state), "unknown", ifelse(is.na(r), "other", r))
}
race_label <- function(code) {
  x <- unname(c("0" = "unknown", "1" = "White", "2" = "Black", "3" = "other", "4" = "Asian", "5" = "Hispanic", "6" = "Native American")[as.character(code)])
  ifelse(is.na(x), "unknown", x)
}

register_baseline_inputs <- function(con, ccw_codes, ndc_drug, ndc_atc) {
  duckdb::duckdb_register(con, "ccw_codes", ccw_codes); duckdb::duckdb_register(con, "ndc_drug", ndc_drug); duckdb::duckdb_register(con, "ndc_atc", ndc_atc)
}

build_baseline <- function(con, cohort = "htn_cohort", out = "htn_base") {
  sql <- paste(readLines(file.path(PROJ_ROOT, "sql", "baseline.sql")), collapse = "\n")
  tmp <- tempfile(fileext = ".sql"); writeLines(gsub("@COHORT@", cohort, sql, fixed = TRUE), tmp)
  run_sql_file(con, basename(tmp), dir = dirname(tmp))
  b <- dbGetQuery(con, "SELECT * FROM htn_base") %>% mutate(
    sex = factor(ifelse(sex == "1", "male", ifelse(sex == "2", "female", "unknown"))),
    race = factor(race_label(race)), region = factor(ssa_region(state)),
    idx_year = factor(idx_year), idx_quarter = factor(paste0("Q", idx_quarter)),
    across(all_of(CCW_GROUPS), as.integer), prior_hosp = as.integer(n_admissions > 0), arm_acei = as.integer(arm == "ACEI"))
  dbWriteTable(con, out, b, overwrite = TRUE)
  log_step("08_baseline", sprintf("%s: %d people, %d covariate columns", cohort, nrow(b), ncol(b)), nrow(b), nrow(b))
  b
}

# Covariates entering the propensity score (names as columns of the baseline data frame)
PS_COVARIATES <- c("age", "sex", "race", "region", "idx_year", "idx_quarter", CCW_GROUPS, "visit_days", "prior_hosp", "n_drugs", "n_classes")

baseline_missingness <- function(b) tibble::tibble(variable = names(b), n_missing = vapply(b, function(x) sum(is.na(x)), 0), n_unknown_level = vapply(b, function(x) if (is.factor(x)) sum(x %in% c("unknown", "other")) else NA_real_, 0))

if (sys.nframe() == 0) {
  suppressPackageStartupMessages(library(stringr))
  con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  ccw <- read_csv(file.path(PROJ_ROOT, "codelists", "ccw_conditions.csv"), col_types = cols(.default = "c")) %>% filter(protocol_group %in% CCW_GROUPS) %>% transmute(grp = protocol_group, code = icd10_code)
  res <- read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_pde_resolution.csv"), col_types = cols(.default = "c")) %>% filter(resolved == "True")
  ndc_rxcui <- res %>% transmute(ndc11, rxcui = rxcuis) %>% separate_rows(rxcui, sep = ";") %>% filter(rxcui != "")
  rxd <- read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_rxcui_drug.csv"), col_types = cols(.default = "c"))
  ndc_drug <- ndc_rxcui %>% inner_join(rxd, by = "rxcui") %>% distinct(ndc11, drug_name)
  ndc_atc <- read_csv(file.path(PROJ_ROOT, "data", "ref", "ndc_atc.csv"), col_types = cols(.default = "c"))
  register_baseline_inputs(con, ccw, ndc_drug, ndc_atc)
  b <- build_baseline(con)
  dir.create(file.path(PROJ_ROOT, "qc", "analysis"), showWarnings = FALSE)
  write_csv(baseline_missingness(b), file.path(PROJ_ROOT, "qc", "analysis", "baseline_missingness.csv"))
  print(summary(b %>% select(all_of(PS_COVARIATES)))); print(table(b$arm, b$region)); print(colSums(b[CCW_GROUPS]))
}
