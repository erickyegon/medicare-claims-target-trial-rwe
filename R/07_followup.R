# Step 07: follow-up, crude outcomes and add-on/switch/discontinuation events for a hypertension cohort. Descriptive only (no outcome models).
#   A-008: ITT follow-up ends at the earliest of day 365, end of data (2023-03-31) and loss of continuous Part A+B+D entitlement.
#   A-007: the add-on/switch-censored sensitivity analysis censors at the first fill of the other study drug only.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(readr); library(survival)})
DATA_END   <- as.Date("2023-03-31")   # end of data (A-008): the last day of the final data month
LAST_CLAIM <- as.Date("2023-03-02")   # last claim date; used only by the old-rule sensitivity analysis
GRACE <- 30L                          # days after the end of supply before a gap counts as discontinuation (descriptive only, A-007)
MIN_CELL <- 11

# Supply timeline for one person's fills of the INDEX class (protocol Section 9).
#   fills: data.frame(fill_dt = Date, days_supply = integer), including the index fill.
#   Early refills carry forward (the new supply starts when the old one ends). A refill within `grace` days after supply
#   ends continues treatment; a later refill (or none) means discontinuation at supply end + grace.
#   other_dt: first fill of the OTHER study drug after index (NA if none). "add-on" if the index class still has supply on that date,
#   otherwise "switch".
supply_timeline <- function(fills, other_dt = as.Date(NA), grace = GRACE) {
  fills <- fills[order(fills$fill_dt), , drop = FALSE]
  cur_end <- as.Date(NA); disc <- as.Date(NA); cover_at_other <- as.Date(NA)
  for (i in seq_len(nrow(fills))) {
    d <- fills$fill_dt[i]
    if (!is.na(cur_end) && d > cur_end + grace) { disc <- cur_end + grace; break }
    start <- if (is.na(cur_end) || d > cur_end) d else cur_end + 1L
    cur_end <- start + fills$days_supply[i] - 1L
    if (!is.na(other_dt) && d <= other_dt) cover_at_other <- cur_end
  }
  if (is.na(disc)) disc <- cur_end + grace
  type <- if (is.na(other_dt)) NA_character_ else if (!is.na(cover_at_other) && other_dt <= cover_at_other && other_dt <= disc) "add-on" else "switch"
  list(discontinuation_dt = disc, other_type = type, last_supply_end = cur_end)
}

# Builds the follow-up table for `cohort` (a cohort table in `con`) and stores it as `out`.
build_followup <- function(con, data_end = DATA_END, cohort = "htn_cohort", out = "htn_fu", last_claim = LAST_CLAIM) {
  sql <- paste(readLines(file.path(PROJ_ROOT, "sql", "followup.sql")), collapse = "\n")
  tmp <- tempfile(fileext = ".sql"); writeLines(gsub("@COHORT@", cohort, gsub("@DATA_END@", format(data_end), sql, fixed = TRUE), fixed = TRUE), tmp)
  run_sql_file(con, basename(tmp), dir = dirname(tmp))
  fu <- dbGetQuery(con, "SELECT * FROM fu_outcomes")
  fills <- dbGetQuery(con, sprintf("SELECT a.BENE_ID, a.fill_dt, a.days_supply, a.ahtn_class FROM ahtn_fill a JOIN %s h ON h.BENE_ID = a.BENE_ID
                            WHERE a.ahtn_class IN ('ACEI', 'THIAZIDE') AND a.fill_dt >= h.idx", cohort))
  by_p <- split(fills, fills$BENE_ID)
  res <- lapply(seq_len(nrow(fu)), function(i) {
    f <- by_p[[as.character(fu$BENE_ID[i])]]; arm <- fu$arm[i]; other <- if (arm == "ACEI") "THIAZIDE" else "ACEI"
    own <- f[f$ahtn_class == arm, c("fill_dt", "days_supply")]; oth <- f$fill_dt[f$ahtn_class == other & f$fill_dt > fu$idx[i]]
    tl <- supply_timeline(own, if (length(oth)) min(oth) else as.Date(NA))
    tibble::tibble(other_dt = if (length(oth)) min(oth) else as.Date(NA), other_type = tl$other_type, disc_dt = tl$discontinuation_dt, idx_days_supply = own$days_supply[own$fill_dt == fu$idx[i]][1])
  })
  fu <- bind_cols(fu, bind_rows(res)) %>% mutate(
    # primary ITT end (A-008) and the two sensitivity rules
    itt_end = pmin(idx + 365, data_end, abd_end),
    itt_end_reason = case_when(itt_end == idx + 365 ~ "day 365", itt_end == data_end ~ "end of data", TRUE ~ "loss of Part A/B/D"),
    itt_end_ab = pmin(idx + 365, data_end, ab_end),                     # sensitivity: ignore loss of Part D
    itt_end_old = pmin(idx + 365, last_claim, ab_end),                  # sensitivity: v0.3 rule (last claim date, Part A+B only)
    hosp_dt = if_else(!is.na(first_adm) & first_adm <= itt_end, first_adm, as.Date(NA)),
    fx_dt = if_else(!is.na(first_fx) & first_fx <= itt_end, first_fx, as.Date(NA)),
    # add-on/switch-censored sensitivity analysis (A-007): censor at the first fill of the other study drug only
    as_end = pmin(itt_end, if_else(is.na(other_dt), as.Date("2100-01-01"), other_dt)),
    as_end_reason = case_when(!is.na(other_dt) & as_end == other_dt & other_dt < itt_end ~ other_type, TRUE ~ itt_end_reason),
    hosp_as = if_else(!is.na(first_adm) & first_adm <= as_end, first_adm, as.Date(NA)),
    # descriptive time to the first of add-on / switch / discontinuation, censored at the end of ITT follow-up
    first_dt = pmin(other_dt, disc_dt, na.rm = TRUE),
    first_type = case_when(!is.na(other_dt) & other_dt <= disc_dt ~ other_type, TRUE ~ "discontinuation"),
    event_ok = first_dt <= itt_end,
    tt_status = ifelse(event_ok, first_type, "censored"), tt_time = as.numeric(if_else(event_ok, first_dt, itt_end) - idx))
  dbWriteTable(con, out, fu, overwrite = TRUE)
  log_step("07_followup", sprintf("%s: %d people; hospitalization in ITT window %d; ITT ended by day 365 for %d", cohort, nrow(fu), sum(!is.na(fu$hosp_dt)), sum(fu$itt_end_reason == "day 365")), nrow(fu), nrow(fu))
  fu
}

flag <- function(n) n < MIN_CELL
crude_events <- function(fu) {
  fu %>% group_by(arm) %>% summarise(
    n = n(), n_full_365 = sum(itt_end == idx + 365), n_full_30 = sum(itt_end >= idx + 30),
    hosp_365_itt = sum(!is.na(hosp_dt)), py_itt = sum(as.numeric(pmin(hosp_dt, itt_end, na.rm = TRUE) - idx)) / 365.25,
    hosp_365_among_full_365 = sum(!is.na(hosp_dt) & itt_end == idx + 365),
    hosp_30 = sum(!is.na(hosp_dt) & hosp_dt <= idx + 30), hosp_30_among_full_30 = sum(!is.na(hosp_dt) & hosp_dt <= idx + 30 & itt_end >= idx + 30),
    fracture_365_itt = sum(!is.na(fx_dt)), py_fracture = sum(as.numeric(pmin(fx_dt, itt_end, na.rm = TRUE) - idx)) / 365.25,
    hosp_365_addon_switch_censored = sum(!is.na(hosp_as)), py_addon_switch_censored = sum(as.numeric(pmin(hosp_as, as_end, na.rm = TRUE) - idx)) / 365.25, .groups = "drop") %>%
    mutate(crude_risk_365_pct_among_full = round(100 * hosp_365_among_full_365 / n_full_365, 1), crude_risk_30_pct_among_full = round(100 * hosp_30_among_full_30 / n_full_30, 1),
           py_itt = round(py_itt, 1), py_fracture = round(py_fracture, 1), py_addon_switch_censored = round(py_addon_switch_censored, 1),
           flag_lt11 = flag(hosp_365_itt) | flag(hosp_30) | flag(fracture_365_itt) | flag(hosp_365_addon_switch_censored))
}

# Cumulative incidence (Aalen-Johansen) of the first add-on / switch / discontinuation event, by arm, at 30/90/180/365 days
timing_tables <- function(fu) {
  fu$status <- factor(fu$tt_status, levels = c("censored", "add-on", "switch", "discontinuation"))
  cif <- do.call(rbind, lapply(split(fu, fu$arm), function(d) {
    fit <- survfit(Surv(tt_time, status) ~ 1, data = d)
    s <- summary(fit, times = c(30, 90, 180, 365), extend = TRUE)
    o <- as.data.frame(s$pstate); names(o) <- fit$states
    cbind(arm = d$arm[1], day = c(30, 90, 180, 365), round(100 * o[, c("add-on", "switch", "discontinuation")], 1))
  }))
  names(cif)[3:5] <- paste0("cum_inc_pct_", c("addon", "switch", "discontinuation"))
  counts <- fu %>% group_by(arm) %>% summarise(n = n(), n_addon = sum(tt_status == "add-on"), n_switch = sum(tt_status == "switch"), n_discontinued = sum(tt_status == "discontinuation"),
      n_censored_before_any = sum(tt_status == "censored"),
      median_days_addon = median(tt_time[tt_status == "add-on"]), median_days_switch = median(tt_time[tt_status == "switch"]), median_days_discontinuation = median(tt_time[tt_status == "discontinuation"]),
      idx_days_supply_median = median(idx_days_supply, na.rm = TRUE), idx_days_supply_q1 = quantile(idx_days_supply, .25, na.rm = TRUE), idx_days_supply_q3 = quantile(idx_days_supply, .75, na.rm = TRUE),
      any_other_study_drug_fill_in_itt = sum(!is.na(other_dt) & other_dt <= itt_end), .groups = "drop") %>%
    mutate(flag_lt11 = n_addon < MIN_CELL | n_switch < MIN_CELL | n_discontinued < MIN_CELL)
  list(cif = cif, counts = counts,
       itt_end_reasons = fu %>% count(arm, itt_end_reason) %>% group_by(arm) %>% mutate(pct = round(100 * n / sum(n), 1)) %>% ungroup(),
       addon_switch_end_reasons = fu %>% count(arm, as_end_reason) %>% group_by(arm) %>% mutate(pct = round(100 * n / sum(n), 1)) %>% ungroup())
}

if (sys.nframe() == 0) {
  con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  icd_fx <- read_csv(file.path(PROJ_ROOT, "codelists", "icd10_exclusions.csv"), col_types = cols(.default = "c")) %>% filter(role == "negative_control_outcome") %>% transmute(code = icd10_code)
  duckdb::duckdb_register(con, "icd_fx", icd_fx)
  fu <- build_followup(con); ce <- crude_events(fu); tt <- timing_tables(fu); out <- file.path(PROJ_ROOT, "qc", "cohort")
  write_csv(ce, file.path(out, "crude_events.csv")); for (n in names(tt)) write_csv(tt[[n]], file.path(out, paste0("timing_", n, ".csv")))
  print(as.data.frame(ce)); print(tt$itt_end_reasons); print(as.data.frame(tt$counts[, 1:8]))
}
