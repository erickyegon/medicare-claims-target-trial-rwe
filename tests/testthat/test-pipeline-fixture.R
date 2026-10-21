# End-to-end smoke test on the synthetic fixture: raw-schema tables -> enrollment -> canonical tables -> cohort -> follow-up -> baseline -> PS/IPTW -> bootstrap.
source(file.path(.root, "R", "08_baseline.R")); source(file.path(.root, "R", "09_analysis_functions.R"))

test_that("the whole pipeline runs on the synthetic fixture and gives coherent results", {
  con <- new_con(); on.exit(dbDisconnect(con, shutdown = TRUE))
  make_fixture_raw(con, n = 700, seed = 42)
  expect_equal(dbGetQuery(con, "SELECT count(DISTINCT BENE_ID) FROM bene")[[1]], 700)
  build_enrollment(con); run_sql_file(con, "canonical.sql"); fixture_lookups(con)
  r <- build_cohort(con, log = FALSE)
  a <- r$attrition
  expect_equal(a$step, 0:10); expect_true(all(diff(a$n_persons[2:11]) <= 0))          # attrition never adds people (steps 1-10)
  expect_equal(a$n_persons[1], 700); expect_equal(a$n_persons[11], sum(r$arms$n))
  expect_true(all(r$arms$n >= 30))                                                       # both arms populated
  expect_true(all(r$sensitivity_cohorts$n_persons > 0))
  fu <- build_followup(con); ce <- crude_events(fu)
  expect_equal(nrow(fu), a$n_persons[11]); expect_true(all(fu$itt_end >= fu$idx)); expect_true(all(fu$itt_end <= fu$idx + 365))
  expect_true("day 365" %in% fu$itt_end_reason); expect_true(all(fu$itt_end_reason %in% c("day 365", "end of data", "loss of Part A/B/D")))
  expect_true(all(ce$hosp_365_itt >= 0))
  b <- build_baseline(con, "htn_cohort", "base_fx")
  expect_equal(nrow(b), nrow(fu)); expect_true(all(b$age >= 65))
  p <- prepare_ps_data(b %>% mutate(arm_acei = as.integer(arm == "ACEI")), c("age", "sex", "race", "region", "idx_year", "diabetes", "ischemic_heart_disease", "visit_days", "prior_hosp"))
  d <- inner_join(p$data, fu %>% select(BENE_ID, itt_end, first_adm), by = "BENE_ID") %>% mutate(event = !is.na(first_adm) & first_adm <= itt_end, time = ifelse(event, as.numeric(first_adm - idx), as.numeric(itt_end - idx))) %>% filter(time >= 1)
  ps <- fit_ps(d, p$covars)$ps; w <- iptw(d$arm_acei, ps)
  expect_true(all(ps > 0 & ps < 1)); expect_true(all(w > 0))
  smd0 <- smd_table(d, p$covars); smd1 <- smd_table(d, p$covars, w = w)
  expect_lte(max(abs(smd1$smd)), max(abs(smd0$smd)) + 1e-9)                              # weighting does not worsen the worst imbalance
  est <- function(dat) { pp <- fit_ps(dat, p$covars)$ps; ww <- iptw(dat$arm_acei, pp); rk <- risk_km(agg_counts(dat$time, dat$event, ww, dat$arm_acei, 365)); list(scalars = risks_at(rk, 365), curve = NULL) }
  bt <- bootstrap(d, est, B = 8, seed = 1)
  expect_equal(bt$n_ok, 8); expect_true(all(bt$ci[c("risk_acei", "risk_thiazide"), "estimate"] >= 0 & bt$ci[c("risk_acei", "risk_thiazide"), "estimate"] <= 1))
})
