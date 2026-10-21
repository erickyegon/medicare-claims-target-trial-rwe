source(file.path(.root, "R", "09_analysis_functions.R"))
library(survival)

sim_data <- function(n = 2000, seed = 1, haz = c(0.0008, 0.0012), cens_day = 365) {
  set.seed(seed); arm <- rbinom(n, 1, 0.5)
  t_ev <- ceiling(rexp(n, ifelse(arm == 1, haz[2], haz[1])))
  t_c <- pmin(cens_day, ceiling(runif(n, 100, 400)))
  data.frame(arm = arm, time = pmin(t_ev, t_c), event = t_ev <= t_c, w = runif(n, 0.5, 2))
}

test_that("rare factor levels are pooled and rare indicators are dropped from the PS model", {
  b <- data.frame(arm_acei = rep(0:1, 50), age = 65:164, f = factor(c(rep("a", 60), rep("b", 35), rep("c", 4), "d")), z = c(rep(0, 100)),
                  rare = c(rep(0, 93), rep(1, 7)), ok = rep(0:1, 50))
  p <- prepare_ps_data(b, c("age", "f", "z", "rare", "ok"), min_n = 10)
  expect_setequal(p$dropped, c("z", "rare"))                       # constant, and only 7 people with the characteristic
  expect_false(any(c("c", "d", "rare") %in% levels(p$data$f)))     # levels c (4) and d (1) pooled (5 people, still < 10) and merged into the most frequent level
  expect_equal(sum(p$data$f == "a"), 65); expect_equal(sum(p$data$f == "b"), 35)
  b2 <- b; b2$f <- factor(c(rep("a", 50), rep("b", 35), rep("c", 8), rep("d", 7)))
  p2 <- prepare_ps_data(b2, "f", min_n = 10); expect_true("rare" %in% levels(p2$data$f)); expect_equal(sum(p2$data$f == "rare"), 15)   # pooled level large enough: kept as "rare"
  expect_setequal(p$covars, c("age", "f", "ok"))
})

test_that("stabilized weights and truncation are computed as specified", {
  a <- c(1, 1, 0, 0, 0); ps <- c(0.8, 0.5, 0.5, 0.2, 0.1)
  w <- iptw(a, ps, trunc = NULL); pa <- 0.4
  expect_equal(w, c(pa / 0.8, pa / 0.5, 0.6 / 0.5, 0.6 / 0.8, 0.6 / 0.9))
  set.seed(2); ps2 <- plogis(rnorm(1000, -0.5, 1.5)); a2 <- rbinom(1000, 1, ps2); w2 <- iptw(a2, ps2)
  raw <- iptw(a2, ps2, NULL); q <- quantile(raw, c(0.01, 0.99))
  expect_equal(range(w2), as.numeric(q)); expect_true(all(w2 >= q[1] & w2 <= q[2]))
  expect_equal(mean(raw), 1, tolerance = 0.15)                      # stabilized weights average about 1
})

test_that("weighted SMD and effective sample size", {
  d <- data.frame(arm_acei = c(1, 1, 1, 1, 0, 0, 0, 0), x = c(1, 2, 3, 4, 1, 2, 3, 4) + c(1, 1, 1, 1, 0, 0, 0, 0), g = factor(c("u", "u", "v", "v", "u", "v", "v", "v")))
  s <- smd_table(d, c("x", "g"))
  expect_equal(s$smd[s$covariate == "x"], 1 / sqrt((var(2:5) + var(1:4)) / 2))   # mean difference 1, pooled SD from the two arms
  expect_equal(s$smd[s$covariate == "gv"], (0.5 - 0.75) / sqrt((var(c(0, 0, 1, 1)) + var(c(0, 1, 1, 1))) / 2))
  sw <- smd_table(d, "x", w = rep(2, 8)); expect_equal(sw$smd, s$smd[s$covariate == "x"])   # equal weights change nothing
  expect_equal(effective_n(c(1, 1, 1, 1)), 4); expect_equal(effective_n(c(4, 0.0001, 0.0001)), 1, tolerance = 1e-3)
})

test_that("aggregated weighted hazards reproduce the weighted Kaplan-Meier estimator", {
  d <- sim_data()
  agg <- agg_counts(d$time, d$event, d$w, d$arm, 365); rk <- risk_km(agg)
  for (a in 0:1) {
    s <- summary(survfit(Surv(time, event) ~ 1, data = d[d$arm == a, ], weights = w), times = 365, extend = TRUE)
    expect_equal(rk$cuminc[rk$day == 365 & rk$arm == a], 1 - s$surv, tolerance = 1e-9)
  }
  r30 <- risks_at(rk, 30); s30 <- summary(survfit(Surv(time, event) ~ arm, data = d, weights = w), times = 30, extend = TRUE)
  expect_equal(unname(r30[c("risk_thiazide", "risk_acei")]), 1 - s30$surv, tolerance = 1e-9)
  # horizon truncation: events and at-risk beyond the horizon do not leak in
  a100 <- agg_counts(d$time, d$event, d$w, d$arm, 100); expect_equal(sum(a100$ev[a100$arm == 1]), sum(d$w[d$arm == 1 & d$event & d$time <= 100]))
})

test_that("pooled logistic risk agrees with Kaplan-Meier when hazards are smooth", {
  d <- sim_data(n = 6000, seed = 3, haz = c(0.0008, 0.0016)); w <- rep(1, nrow(d))
  agg <- agg_counts(d$time, d$event, w, d$arm, 365)
  km <- risks_at(risk_km(agg), 365); pl <- risks_at(risk_pooled(agg), 365)
  expect_equal(unname(pl["risk_acei"]), unname(km["risk_acei"]), tolerance = 0.01)
  expect_equal(unname(pl["risk_thiazide"]), unname(km["risk_thiazide"]), tolerance = 0.01)
  expect_equal(unname(km["rd"]), unname(km["risk_acei"] - km["risk_thiazide"])); expect_equal(unname(km["rr"]), unname(km["risk_acei"] / km["risk_thiazide"]))
})

test_that("matching respects the caliper and uses each unit once", {
  set.seed(5); n <- 400; a <- rbinom(n, 1, 0.4); ps <- plogis(rnorm(n, ifelse(a == 1, 0.4, -0.2), 1))
  m <- ps_match(a, ps, 0.2, seed = 9)
  lp <- qlogis(ps); cal <- 0.2 * sd(lp)
  expect_true(all(abs(lp[m[, 1]] - lp[m[, 2]]) <= cal + 1e-12))
  expect_equal(anyDuplicated(c(m[, 1], m[, 2])), 0)
  expect_true(all(a[m[, 1]] != a[m[, 2]])); expect_true(nrow(m) <= min(sum(a == 1), sum(a == 0)))
  expect_equal(ps_match(a, ps, 0.2, seed = 9), m)                    # reproducible for a fixed seed
  expect_lt(nrow(ps_match(a, ps, 0.001, seed = 9)), nrow(m))         # a tighter caliper keeps fewer pairs
  set.seed(10); r1 <- runif(1); set.seed(10); invisible(ps_match(a, ps, 0.2, seed = 9)); r2 <- runif(1)
  expect_equal(r1, r2)                                               # matching does not disturb the caller random-number stream (bootstrap safety)
})

test_that("E-value formula", {
  expect_equal(unname(evalue(2)["point"]), 2 + sqrt(2), tolerance = 1e-12)
  expect_equal(unname(evalue(0.5)["point"]), 2 + sqrt(2), tolerance = 1e-12)       # protective estimates are inverted
  expect_equal(unname(evalue(1)["point"]), 1)
  expect_equal(unname(evalue(1.5, lo = 0.9, hi = 2.5)["ci_limit"]), 1)               # CI includes the null
  expect_equal(unname(evalue(2, lo = 1.5, hi = 2.7)["ci_limit"]), 1.5 + sqrt(1.5 * 0.5), tolerance = 1e-12)
})

test_that("IPCW multipliers: neutral without censoring, directed by the covariates otherwise", {
  set.seed(7); n <- 4000
  arm <- rbinom(n, 1, 0.5); agegrp <- factor(sample(c("65-74", "75-84", "85+"), n, TRUE)); sex <- factor(sample(c("f", "m"), n, TRUE))
  cday <- rep(365L, n); none <- ipcw_multipliers(cday, rep(FALSE, n), arm, agegrp, sex, 365)
  expect_equal(max(abs(none$cw - 1)), 0, tolerance = 1e-6)
  cd <- ceiling(rexp(n, ifelse(sex == "m", 0.004, 0.0004))); ev <- cd <= 365; cd <- pmin(cd, 365L)
  m <- ipcw_multipliers(cd, ev, arm, agegrp, sex, 365)
  cells <- levels(interaction(arm, agegrp, sex, drop = TRUE, sep = "|"))
  hi <- grepl("m$", cells); expect_true(all(m$cw[365, hi] > 1)); expect_true(all(m$cw[365, !hi] < 1))   # higher censoring hazard -> larger multiplier
  expect_true(all(m$cw[1, ] > 0.99 & m$cw[1, ] < 1.01))                                                  # multipliers start near 1
  # time-varying machinery with unit multipliers equals the constant-weight estimate
  d <- sim_data(1000, 11); cell <- rep(1L, nrow(d)); cw1 <- matrix(1, 365, 1)
  expect_equal(agg_counts(d$time, d$event, d$w, d$arm, 365), agg_counts(d$time, d$event, d$w, d$arm, 365, cell, cw1))
  cw2 <- matrix(2, 365, 1); a2 <- agg_counts(d$time, d$event, d$w, d$arm, 365, cell, cw2); a1 <- agg_counts(d$time, d$event, d$w, d$arm, 365)
  expect_equal(a2$ev, 2 * a1$ev); expect_equal(a2$risk, 2 * a1$risk)                                      # a constant multiplier scales counts, not hazards
})

test_that("bootstrap is reproducible and brackets the point estimate for a well-behaved estimator", {
  d <- data.frame(x = rnorm(300, 5, 2))
  est <- function(dat) list(scalars = c(mean = mean(dat$x)), curve = NULL)
  set.seed(1); b1 <- bootstrap(d, est, B = 200, seed = 4); b2 <- bootstrap(d, est, B = 200, seed = 4)
  expect_equal(b1$ci, b2$ci)
  expect_true(b1$ci["mean", "lo"] < b1$ci["mean", "estimate"] && b1$ci["mean", "estimate"] < b1$ci["mean", "hi"])
  expect_equal(b1$n_ok, 200)
})

test_that("person-month IPCW for loss of entitlement: neutral without censoring, directed by covariates, consistent with the count machinery", {
  set.seed(21); n <- 3000
  d <- data.frame(arm_acei = rbinom(n, 1, 0.5), age = round(runif(n, 65, 90)), male = rbinom(n, 1, 0.5))
  M0 <- ipcw_person_month(d, rep(365L, n), rep(FALSE, n), c("age", "male"), 365)
  expect_equal(dim(M0), c(n, 365)); expect_equal(max(abs(M0 - 1)), 0, tolerance = 1e-6)
  cd <- ceiling(rexp(n, ifelse(d$male == 1, 0.004, 0.0004))); ev <- cd <= 365; cd <- pmin(cd, 365L)
  M <- ipcw_person_month(d, cd, ev, c("age", "male"), 365)
  expect_true(mean(M[d$male == 1, 365]) > 1 && mean(M[d$male == 0, 365]) < 1)       # higher censoring hazard -> larger multiplier
  # analytic check for the first 30-day interval: daily hazards 0.004 (men) and 0.0004 (women); numerator hazard is their average (0.0022)
  expect_equal(mean(M[d$male == 1, 1]), exp(-0.0022 * 30) / exp(-0.004 * 30), tolerance = 0.02)    # about 1.055
  expect_equal(mean(M[d$male == 0, 1]), exp(-0.0022 * 30) / exp(-0.0004 * 30), tolerance = 0.02)   # about 0.947
  expect_equal(M[, 1], M[, 30]); expect_true(all(M[, 31] != M[, 30]))               # constant within a 30-day interval, changes between intervals
  # with unit multipliers the person-level aggregation equals the plain aggregation
  dd <- sim_data(800, 5); one <- matrix(1, nrow(dd), 365)
  expect_equal(agg_counts_person(dd$time, dd$event, dd$w, dd$arm, 365, one), agg_counts(dd$time, dd$event, dd$w, dd$arm, 365))
  # and with cell-constant multipliers it equals the cell-based aggregation
  cell <- sample(1:3, nrow(dd), TRUE); cw <- cbind(seq(1, 2, length.out = 365), seq(1, 0.5, length.out = 365), rep(1.3, 365))
  expect_equal(agg_counts_person(dd$time, dd$event, dd$w, dd$arm, 365, cw[, cell] |> t()), agg_counts(dd$time, dd$event, dd$w, dd$arm, 365, cell, cw))
})
