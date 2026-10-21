# Step 09: Phase 4 analysis driver (protocol v0.4). Primary: ITT 365-day all-cause hospitalization, ACE inhibitor vs thiazide, stabilized IPTW
# (truncated 1st/99th percentile), weighted KM and weighted pooled logistic, RD and RR with 95% percentile CIs from 500 bootstrap resamples of
# individuals (PS refitted in every resample). Secondary: 30-day hospitalization. Negative control: descriptive only (A-006).
# Sensitivity analyses: A-007 (add-on/switch censoring with IPCW), A-008 (follow-up rules), A-009 (strict diagnosis window), A-010 (co-starters kept,
# baseline fills with no RxNorm record excluded), matching, untruncated weights, CKD excluded, unadjusted. Outputs: qc/analysis/*.csv and qc/analysis/figs/*.png.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "08_baseline.R")); source(file.path(.root, "R", "07_followup.R")); source(file.path(.root, "R", "09_analysis_functions.R"))
suppressPackageStartupMessages({library(ggplot2); library(stringr)})
IPCW_LOSS_COVARS <- c("age", "sex", "region", "prior_hosp", "diabetes", "chronic_kidney_disease", "ischemic_heart_disease")   # parsimonious: about 75 censoring events
B_REPS <- as.integer(Sys.getenv("RWE_BOOT", "500")); SEED <- 20261020; HORIZON <- 365L
OUT <- file.path(PROJ_ROOT, "qc", "analysis"); FIG <- file.path(OUT, "figs"); dir.create(FIG, recursive = TRUE, showWarnings = FALSE)
r4 <- function(x) round(x, 4)

# ---- inputs -------------------------------------------------------------------------------------------------------------
con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
run_sql_file(con, "canonical.sql")   # refresh canonical tables
ccw <- read_csv(file.path(PROJ_ROOT, "codelists", "ccw_conditions.csv"), col_types = cols(.default = "c")) %>% filter(protocol_group %in% CCW_GROUPS) %>% transmute(grp = protocol_group, code = icd10_code)
res <- read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_pde_resolution.csv"), col_types = cols(.default = "c")) %>% filter(resolved == "True")
ndc_rxcui <- res %>% transmute(ndc11, rxcui = rxcuis) %>% separate_rows(rxcui, sep = ";") %>% filter(rxcui != "")
ndc_drug <- ndc_rxcui %>% inner_join(read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_rxcui_drug.csv"), col_types = cols(.default = "c")), by = "rxcui") %>% distinct(ndc11, drug_name)
ndc_atc <- read_csv(file.path(PROJ_ROOT, "data", "ref", "ndc_atc.csv"), col_types = cols(.default = "c"))
register_baseline_inputs(con, ccw, ndc_drug, ndc_atc)
icd_fx <- read_csv(file.path(PROJ_ROOT, "codelists", "icd10_exclusions.csv"), col_types = cols(.default = "c")) %>% filter(role == "negative_control_outcome") %>% transmute(code = icd10_code)
duckdb::duckdb_register(con, "icd_fx", icd_fx)

# Analysis data frame: baseline covariates + outcome times under a chosen ITT end column
make_analysis_df <- function(cohort, end_col = "itt_end", tag = cohort) {
  b <- build_baseline(con, cohort, paste0("base_", tag)); fu <- build_followup(con, cohort = cohort, out = paste0("fu_", tag))
  d <- b %>% inner_join(fu %>% select(BENE_ID, itt_end, itt_end_reason, itt_end_ab, itt_end_old, as_end, first_adm, other_dt, other_type), by = "BENE_ID") %>%
    mutate(end = .data[[end_col]], event = !is.na(first_adm) & first_adm <= end, ev_day = as.numeric(first_adm - idx), cens_day = as.numeric(end - idx),
           time = ifelse(event, ev_day, cens_day),
           # add-on/switch-censored version (A-007)
           as_event = !is.na(first_adm) & first_adm <= as_end, as_time = ifelse(as_event, ev_day, as.numeric(as_end - idx)),
           c_event = !is.na(other_dt) & other_dt < itt_end, c_day = as.numeric(ifelse(c_event, other_dt - idx, itt_end - idx)),
           c2_event = itt_end_reason == "loss of Part A/B/D" & end == itt_end, c2_day = as.numeric(end - idx),   # loss of entitlement as the censoring event (IPCW sensitivity)
           agegrp = factor(cut(age, c(64, 74, 84, Inf), labels = c("65-74", "75-84", "85+"))), costart = as.integer(costart))
  n0 <- nrow(d); d <- d %>% filter(time >= 1, as_time >= 1)
  attr(d, "dropped_zero_followup") <- n0 - nrow(d); d
}

# ---- estimators ------------------------------------------------------------------------------------------------------------
scal <- function(rk, prefix) { out <- c(); for (h in c(365, 30)) { v <- risks_at(rk, h); names(v) <- paste0(prefix, h, "_", names(v)); out <- c(out, v) }; out }
make_estimator <- function(type, covars, trunc = c(0.01, 0.99), horizon = HORIZON) function(dat) {
  if (type == "unadjusted") { w <- rep(1, nrow(dat)); a <- dat }
  else if (type == "match") {
    ps <- fit_ps(dat, covars)$ps; m <- ps_match(dat$arm_acei, ps, 0.2, seed = 1); a <- dat[c(m[, 1], m[, 2]), ]; w <- rep(1, nrow(a))
  } else { ps <- fit_ps(dat, covars)$ps; w <- iptw(dat$arm_acei, ps, trunc); a <- dat }
  if (type == "ipcw_loss") {
    M <- ipcw_person_month(a, a$c2_day, a$c2_event, IPCW_LOSS_COVARS, horizon)
    agg <- agg_counts_person(a$time, a$event, w, a$arm_acei, horizon, M)
  } else if (type == "ipcw") {
    ip <- ipcw_multipliers(a$c_day, a$c_event, a$arm_acei, a$agegrp, a$sex, horizon)
    agg <- agg_counts(a$as_time, a$as_event, w, a$arm_acei, horizon, ip$cell, ip$cw)
  } else agg <- agg_counts(a$time, a$event, w, a$arm_acei, horizon)
  km <- risk_km(agg); pl <- risk_pooled(agg)
  list(scalars = c(scal(km, "km"), scal(pl, "pl")), curve = c(km$cuminc[km$arm == 0], km$cuminc[km$arm == 1]))
}
tidy_ci <- function(bt) { x <- as.data.frame(bt$ci); x$stat <- rownames(x); rownames(x) <- NULL
  x %>% mutate(method = ifelse(grepl("^km", stat), "weighted KM", "weighted pooled logistic"), horizon = as.integer(str_extract(stat, "(?<=^(km|pl))[0-9]+")), quantity = sub("^(km|pl)[0-9]+_", "", stat)) %>%
    select(method, horizon, quantity, estimate, lo, hi) }

# ---- primary analysis ----------------------------------------------------------------------------------------------------
t0 <- Sys.time()
prim <- make_analysis_df("htn_cohort", "itt_end", "primary")
pp <- prepare_ps_data(prim, PS_COVARIATES); dat <- pp$data; covars <- pp$covars
message("PS covariates dropped (fewer than 10 people): ", paste(pp$dropped, collapse = ", "), "; rare factor levels pooled")
log_step("09_analysis", sprintf("primary cohort: %d people (zero-follow-up dropped: %d); PS covariates %d (dropped: %s)", nrow(dat), attr(prim, "dropped_zero_followup"), length(covars), paste(pp$dropped, collapse = ",")), nrow(prim), nrow(dat))

psfit <- fit_ps(dat, covars); dat$ps <- psfit$ps; dat$w_raw <- iptw(dat$arm_acei, dat$ps, NULL); dat$w <- iptw(dat$arm_acei, dat$ps, c(0.01, 0.99))
auc <- local({ r <- rank(dat$ps); n1 <- sum(dat$arm_acei == 1); n0 <- sum(dat$arm_acei == 0); (sum(r[dat$arm_acei == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0) })
dbWriteTable(con, "analysis_primary", dat %>% select(BENE_ID, arm_acei, ps, w_raw, w), overwrite = TRUE)   # person-level PS and weights stay in the git-ignored database
local({
  Mx <- ipcw_person_month(dat, dat$c2_day, dat$c2_event, IPCW_LOSS_COVARS, HORIZON); wl <- dat$w * Mx[, HORIZON]
  write_csv(tibble::tibble(item = c("censoring events (loss of A/B/D before day 365 and before end of data)", "IPCW multiplier at day 365: minimum", "median", "maximum", "combined IPTW x IPCW weight at day 365: maximum"),
                           value = r4(c(sum(dat$c2_event), min(Mx[, HORIZON]), median(Mx[, HORIZON]), max(Mx[, HORIZON]), max(wl)))), file.path(OUT, "ipcw_loss_diagnostics.csv"))
})
write_csv(dat %>% group_by(arm = ifelse(arm_acei == 1, "ACEI", "THIAZIDE")) %>% summarise(n = n(), ps_min = r4(min(ps)), ps_p01 = r4(quantile(ps, .01)), ps_median = r4(median(ps)), ps_p99 = r4(quantile(ps, .99)), ps_max = r4(max(ps)),
          weight_min = r4(min(w)), weight_median = r4(median(w)), weight_max = r4(max(w)), weight_mean = r4(mean(w)), effective_n = r4(effective_n(w)), n_truncated = sum(w != w_raw), .groups = "drop") %>% mutate(ps_c_statistic = r4(auc)),
          file.path(OUT, "ps_and_weights_summary.csv"))
bal <- smd_table(dat, covars) %>% rename(smd_unweighted = smd) %>% left_join(smd_table(dat, covars, w = dat$w) %>% select(covariate, smd_weighted = smd, wmean_acei = mean_acei, wmean_thiazide = mean_thiazide), by = "covariate")
write_csv(bal %>% mutate(across(where(is.numeric), r4)), file.path(OUT, "balance_smd.csv"))
message(sprintf("max |SMD| unweighted %.3f, weighted %.3f; PS c-statistic %.3f", max(abs(bal$smd_unweighted)), max(abs(bal$smd_weighted)), auc))

# verification of my weights and SMDs against WeightIt and cobalt (same stabilized ATE definition, before truncation)
chk <- tryCatch({
  wi <- WeightIt::weightit(ps_formula(covars), data = dat, method = "glm", estimand = "ATE", stabilize = TRUE)
  f_simple <- as.formula(paste("arm_acei ~", paste(covars, collapse = " + ")))
  cb <- cobalt::bal.tab(f_simple, data = dat, weights = dat$w_raw, estimand = "ATE", binary = "std", s.d.denom = "pooled", un = TRUE, disp.v.ratio = FALSE)$Balance
  mine_un <- smd_table(dat, covars); mine_w <- smd_table(dat, covars, w = dat$w_raw)
  key <- function(x) gsub("[^A-Za-z0-9]", "", x)                       # cobalt writes race_White, I write raceWhite
  cbk <- tibble::tibble(k = key(rownames(cb)), un = cb$Diff.Un, adj = cb$Diff.Adj); mk <- tibble::tibble(k = key(mine_un$covariate), un = mine_un$smd, adj = mine_w$smd)
  j <- inner_join(mk, cbk, by = "k", suffix = c("_mine", "_cobalt"))
  tibble::tibble(check = c("max |weight difference|: mine (untruncated stabilized ATE) vs WeightIt",
                           sprintf("max |unweighted SMD difference| vs cobalt over %d of %d name-matched columns", nrow(j), nrow(mine_un)),
                           "max |weighted SMD difference| vs cobalt (untruncated weights), same columns"),
                 value = c(max(abs(wi$weights - dat$w_raw)), max(abs(j$un_mine - j$un_cobalt)), max(abs(j$adj_mine - j$adj_cobalt))))
}, error = function(e) tibble::tibble(check = paste("WeightIt/cobalt check failed:", conditionMessage(e)), value = NA_real_))
write_csv(chk, file.path(OUT, "weightit_cobalt_check.csv")); print(as.data.frame(chk))

est_primary <- make_estimator("iptw", covars)
bt <- bootstrap(dat, est_primary, B = B_REPS, seed = SEED)
primary <- tidy_ci(bt) %>% mutate(across(c(estimate, lo, hi), r4))
write_csv(primary, file.path(OUT, "primary_results.csv"))
ev <- evalue(bt$ci["km365_rr", "estimate"], bt$ci["km365_rr", "lo"], bt$ci["km365_rr", "hi"])
write_csv(tibble::tibble(item = c("E-value, point estimate (KM RR, 365 days)", "E-value, confidence limit closer to 1"), value = r4(unname(ev))), file.path(OUT, "evalue.csv"))
counts <- dat %>% group_by(arm = ifelse(arm_acei == 1, "ACEI", "THIAZIDE")) %>% summarise(n = n(), hosp_365_events_unweighted = sum(event), weighted_events = r4(sum(w * event)), weighted_n = r4(sum(w)), .groups = "drop")
write_csv(counts, file.path(OUT, "primary_counts.csv"))

# curves
cv <- tibble::tibble(day = rep(1:HORIZON, 2), arm = rep(c("THIAZIDE", "ACEI"), each = HORIZON), cuminc = bt$point$curve, lo = bt$curve_ci[1, ], hi = bt$curve_ci[2, ])
write_csv(cv %>% mutate(across(c(cuminc, lo, hi), r4)), file.path(OUT, "cumulative_incidence_curves.csv"))
ggsave(file.path(FIG, "cumulative_incidence.png"), ggplot(cv, aes(day, 100 * cuminc, colour = arm, fill = arm)) + geom_ribbon(aes(ymin = 100 * lo, ymax = 100 * hi), alpha = 0.15, colour = NA) + geom_step() +
         labs(x = "Days since index", y = "Cumulative incidence of hospitalization (%)", title = "IPTW-weighted cumulative incidence (95% bootstrap bands)") + theme_minimal(), width = 7, height = 4.5, dpi = 150)
love <- bal %>% mutate(covariate = factor(covariate, levels = covariate[order(abs(smd_unweighted))])) %>% tidyr::pivot_longer(c(smd_unweighted, smd_weighted), names_to = "sample", values_to = "smd")
ggsave(file.path(FIG, "love_plot.png"), ggplot(love, aes(abs(smd), covariate, colour = sample)) + geom_point() + geom_vline(xintercept = 0.1, linetype = 2) + labs(x = "|Standardized mean difference|", y = NULL, title = "Covariate balance before and after IPTW") + theme_minimal(), width = 7, height = 7, dpi = 150)
ggsave(file.path(FIG, "ps_distribution.png"), ggplot(dat %>% mutate(arm = ifelse(arm_acei == 1, "ACEI", "THIAZIDE")), aes(ps, fill = arm)) + geom_density(alpha = 0.4) + labs(x = "Propensity score (probability of ACE inhibitor)", y = "Density", title = "Propensity score distributions by arm") + theme_minimal(), width = 7, height = 4.5, dpi = 150)
message(sprintf("primary analysis done in %.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins"))))

# negative control: descriptive only (A-006)
nc <- crude_events(dbGetQuery(con, "SELECT * FROM fu_primary"))
write_csv(nc %>% select(arm, n, fracture_365_itt, py_fracture), file.path(OUT, "negative_control_descriptive.csv"))

# ---- sensitivity analyses ------------------------------------------------------------------------------------------------
sens_row <- function(label, bt, d, note = "", event_col = "event") {
  ci <- bt$ci; g <- function(s, col) unname(ci[s, col])
  tibble::tibble(analysis = label, n = nrow(d), n_acei = sum(d$arm_acei == 1), n_thiazide = sum(d$arm_acei == 0), events_acei = sum(d[[event_col]][d$arm_acei == 1]), events_thiazide = sum(d[[event_col]][d$arm_acei == 0]),
                 km365_risk_acei = g("km365_risk_acei", "estimate"), km365_risk_thiazide = g("km365_risk_thiazide", "estimate"),
                 km365_rd = g("km365_rd", "estimate"), km365_rd_lo = g("km365_rd", "lo"), km365_rd_hi = g("km365_rd", "hi"),
                 km365_rr = g("km365_rr", "estimate"), km365_rr_lo = g("km365_rr", "lo"), km365_rr_hi = g("km365_rr", "hi"),
                 pl365_rd = g("pl365_rd", "estimate"), pl365_rr = g("pl365_rr", "estimate"), note = note)
}
run_sens <- function(label, cohort, end_col = "itt_end", type = "iptw", covar_add = NULL, filter_fn = NULL, trunc = c(0.01, 0.99), note = "", tag = NULL) {
  tag <- tag %||% gsub("[^a-z0-9]", "_", tolower(label))
  d0 <- if (is.null(cohort)) NULL else make_analysis_df(cohort, end_col, tag)
  if (!is.null(filter_fn)) d0 <- filter_fn(d0)
  p <- prepare_ps_data(d0, c(PS_COVARIATES, covar_add)); d <- p$data
  bts <- bootstrap(d, make_estimator(type, p$covars, trunc), B = B_REPS, seed = SEED)
  message(sprintf("  %-70s n=%d (%.1f min)", label, nrow(d), as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  if (type == "match") {   # report the MATCHED sample (pairs x 2) and its event counts, because that is the sample the estimates come from
    pr <- ps_match(d$arm_acei, fit_ps(d, p$covars)$ps, 0.2, seed = 1); d <- d[c(pr[, 1], pr[, 2]), ]
    note <- sprintf("%s; %d matched pairs (N = %d) in the full sample; N and events are for the matched sample", note, nrow(pr), nrow(d))
  }
  sens_row(label, bts, d, note, if (type == "ipcw") "as_event" else "event")
}
`%||%` <- function(a, b) if (is.null(a)) b else a
sens <- list(
  sens_row("Primary: IPTW, ITT, follow-up to loss of A/B/D, end of data 2023-03-31", bt, dat),
  run_sens("Unadjusted (no weights)", "htn_cohort", type = "unadjusted", note = "reference only"),
  run_sens("Untruncated weights", "htn_cohort", trunc = NULL),
  run_sens("PS matching 1:1, caliper 0.2 SD of the logit (matched sample, ATT)", "htn_cohort", type = "match", note = "pairs formed in each bootstrap resample"),
  run_sens("Keep other-class co-starters, indicator covariate (A-010)", "htn_cohort_costart", covar_add = "costart"),
  run_sens("Exclude any baseline fill with no RxNorm record (A-010)", "htn_cohort_nounid"),
  run_sens("Hypertension diagnosis only in days -365 to -1 (A-009)", "htn_cohort_strictdx"),
  run_sens("ITT follow-up ignoring loss of Part D (A-008)", "htn_cohort", end_col = "itt_end_ab"),
  run_sens("ITT follow-up v0.3 rule: last claim date 2023-03-02, Part A+B only (A-008)", "htn_cohort", end_col = "itt_end_old"),
  run_sens("Exclude chronic kidney disease", "htn_cohort", filter_fn = function(d) d %>% filter(chronic_kidney_disease == 0)),
  run_sens("IPCW for loss of Part A/B/D entitlement, primary ITT outcome (A-013)", "htn_cohort", type = "ipcw_loss", note = "IPTW x stabilized IPCW from a person-month censoring model on baseline covariates"),
  run_sens("Add-on/switch-censored with IPCW (A-007)", "htn_cohort", type = "ipcw", note = "IPTW x stabilized IPCW; risk set censored at the other study drug"))
sensitivity <- bind_rows(sens) %>% mutate(across(where(is.numeric) & !c(n, n_acei, n_thiazide, events_acei, events_thiazide), r4))
write_csv(sensitivity, file.path(OUT, "sensitivity_results.csv"))
log_step("09_analysis", sprintf("analysis complete: %d analyses, %d bootstrap resamples each (primary ok: %d)", length(sens), B_REPS, bt$n_ok), nrow(dat), nrow(dat))
message(sprintf("all analyses done in %.1f min", as.numeric(difftime(Sys.time(), t0, units = "mins"))))
print(as.data.frame(primary)); print(as.data.frame(sensitivity[, c("analysis", "n", "km365_rd", "km365_rd_lo", "km365_rd_hi", "km365_rr", "km365_rr_lo", "km365_rr_hi")]))
