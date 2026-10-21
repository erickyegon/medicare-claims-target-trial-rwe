# Step 09 (functions): propensity score, stabilized IPTW, balance, weighted risk estimation (KM and pooled logistic),
# bootstrap, matching, IPCW and E-value. Pure functions, no database access: tested in tests/testthat/test-analysis.R.
suppressPackageStartupMessages({library(dplyr); library(splines)})

# ---- data preparation --------------------------------------------------------------------------------------------
# Factor levels with fewer than `min_n` people are pooled into "rare"; indicator covariates with fewer than `min_n` people having (or lacking)
# the characteristic are dropped from the propensity score model and reported (modelling note, amendment A-011).
prepare_ps_data <- function(b, covars, min_n = 10) {
  dropped <- character(0)
  for (v in covars) {
    x <- b[[v]]
    if (is.factor(x)) {
      tab <- table(x); rare <- names(tab)[tab < min_n & tab > 0]
      if (length(rare) > 0) {
        levels(x)[levels(x) %in% rare] <- "rare"; x <- droplevels(x)
        # if the pooled level is still smaller than min_n it would be unstable in bootstrap resamples: merge it into the most frequent level
        tab2 <- table(x); if ("rare" %in% names(tab2) && tab2[["rare"]] < min_n && nlevels(x) > 1) { modal <- names(which.max(tab2[names(tab2) != "rare"])); x[x == "rare"] <- modal; x <- droplevels(x) }
        b[[v]] <- x
      }
      if (nlevels(b[[v]]) < 2) dropped <- c(dropped, v)
    } else if (all(x %in% c(0, 1))) {
      if (sum(x == 1) < min_n || sum(x == 0) < min_n) dropped <- c(dropped, v)
    } else if (length(unique(x)) < 2) dropped <- c(dropped, v)
  }
  list(data = b, covars = setdiff(covars, dropped), dropped = dropped)
}

ps_formula <- function(covars, outcome = "arm_acei") {
  terms <- vapply(covars, function(v) switch(v, age = "age + I(age^2)", visit_days = "log1p(visit_days)", v), "")
  as.formula(paste(outcome, "~", paste(terms, collapse = " + ")))
}

# ---- propensity score and weights ----------------------------------------------------------------------------------
fit_ps <- function(d, covars) {
  fit <- suppressWarnings(glm(ps_formula(covars), data = d, family = binomial()))
  list(ps = as.numeric(predict(fit, type = "response")), fit = fit)
}

# Stabilized ATE weights for P(treated) = p_a, truncated at the given quantiles of the weight distribution (protocol: 1st and 99th).
iptw <- function(a, ps, trunc = c(0.01, 0.99)) {
  pa <- mean(a)
  w <- ifelse(a == 1, pa / ps, (1 - pa) / (1 - ps))
  if (!is.null(trunc)) { q <- quantile(w, trunc); w <- pmin(pmax(w, q[1]), q[2]) }
  w
}
effective_n <- function(w) sum(w)^2 / sum(w^2)

# ---- balance --------------------------------------------------------------------------------------------------------
# Standardized mean differences (treated minus control, pooled-SD denominator from the unweighted data) for the model-matrix columns of `covars`.
smd_table <- function(d, covars, a = d$arm_acei, w = rep(1, nrow(d))) {
  mm <- model.matrix(as.formula(paste("~", paste(covars, collapse = " + "))), data = d)[, -1, drop = FALSE]
  wm <- function(x, ww) sum(ww * x) / sum(ww)
  wv <- function(x, ww) { m <- wm(x, ww); sum(ww * (x - m)^2) / sum(ww) }
  do.call(rbind, lapply(colnames(mm), function(v) {
    x <- mm[, v]; i1 <- a == 1; i0 <- a == 0
    sd_pool <- sqrt((var(x[i1]) + var(x[i0])) / 2)
    tibble::tibble(covariate = v, mean_acei = wm(x[i1], w[i1]), mean_thiazide = wm(x[i0], w[i0]),
                   smd = ifelse(sd_pool > 0, (wm(x[i1], w[i1]) - wm(x[i0], w[i0])) / sd_pool, 0))
  }))
}

# ---- weighted discrete-time risk estimation ------------------------------------------------------------------------
# One row per person: time (integer days >= 1 to event or censoring), event (logical), arm (1 = ACE inhibitor, 0 = thiazide).
wsum_by_time <- function(t, w, n) { r <- numeric(n); if (length(t)) { s <- rowsum(w, t); r[as.integer(rownames(s))] <- s[, 1] }; r }

# Weighted events and at-risk mass per day and arm up to `horizon`. `cw` (optional) is a horizon x n_cell matrix of time-varying multipliers
# (IPCW) with `cell` giving each person's column; without it weights are constant per person.
agg_counts <- function(time, event, w, arm, horizon, cell = NULL, cw = NULL) {
  stopifnot(all(time >= 1))
  t <- pmin(time, horizon); e <- event & time <= horizon
  per_arm <- lapply(c(0, 1), function(a) {
    cells <- if (is.null(cell)) 1L else sort(unique(as.integer(cell[arm == a])))
    ev <- rep(0, horizon); risk <- rep(0, horizon)
    for (cc in cells) {
      sel <- arm == a & (if (is.null(cell)) TRUE else as.integer(cell) == cc)
      mult <- if (is.null(cw)) 1 else cw[, cc]
      risk <- risk + mult * rev(cumsum(rev(wsum_by_time(t[sel], w[sel], horizon))))
      ev <- ev + mult * wsum_by_time(t[sel & e], w[sel & e], horizon)
    }
    tibble::tibble(day = seq_len(horizon), arm = a, ev = ev, risk = risk)
  })
  bind_rows(per_arm)
}

risk_km <- function(agg) {   # cumulative incidence per arm: 1 - product(1 - events / at risk); equals the weighted Kaplan-Meier estimate
  agg %>% group_by(arm) %>% mutate(h = ifelse(risk > 0, pmin(ev / risk, 1), 0), cuminc = 1 - cumprod(1 - h)) %>% ungroup()
}
risk_pooled <- function(agg, df_t = 4) {   # weighted pooled logistic regression on person-days with a smooth time effect and an arm-by-time interaction
  a <- agg %>% filter(risk > 0)
  fit <- suppressWarnings(glm(cbind(ev, pmax(risk - ev, 0)) ~ ns(day, df = df_t) * factor(arm), family = quasibinomial(), data = a))
  agg %>% mutate(h = as.numeric(predict(fit, newdata = agg %>% mutate(arm = arm), type = "response"))) %>% group_by(arm) %>% mutate(cuminc = 1 - cumprod(1 - h)) %>% ungroup()
}
contrast <- function(r1, r0) c(risk_acei = r1, risk_thiazide = r0, rd = r1 - r0, rr = r1 / r0)
risks_at <- function(rk, day) { x <- rk$cuminc[rk$day == day]; a <- rk$arm[rk$day == day]; contrast(x[a == 1], x[a == 0]) }

# E-value for a risk ratio (VanderWeele and Ding); `lo`/`hi` give the confidence limits (the limit closer to 1 is used for the CI E-value)
evalue <- function(rr, lo = NA, hi = NA) {
  ev1 <- function(x) { x <- ifelse(x < 1, 1 / x, x); x + sqrt(x * (x - 1)) }
  point <- ev1(rr)
  ci <- if (is.na(lo) || is.na(hi)) NA else if (lo <= 1 && hi >= 1) 1 else ev1(if (rr >= 1) lo else hi)
  c(point = point, ci_limit = ci)
}

# ---- matching ----------------------------------------------------------------------------------------------------------
# Greedy 1:1 nearest-neighbour matching on the logit of the propensity score without replacement, caliper = `caliper_sd` x SD of the logit.
# The smaller arm is matched to the larger; units are processed in a random order set by `seed`. Returns row indices of matched pairs.
ps_match <- function(a, ps, caliper_sd = 0.2, seed = 1) {
  lp <- qlogis(ps); cal <- caliper_sd * sd(lp)
  small <- if (sum(a == 1) <= sum(a == 0)) 1 else 0
  si <- which(a == small); ci <- which(a != small)
  # local RNG: restore the caller's random-number state on exit so a bootstrap loop around this function keeps its own stream
  had_seed <- exists(".Random.seed", envir = globalenv()); old_seed <- if (had_seed) get(".Random.seed", envir = globalenv())
  on.exit(if (had_seed) assign(".Random.seed", old_seed, envir = globalenv()), add = TRUE)
  set.seed(seed); si <- si[sample.int(length(si))]
  avail <- rep(TRUE, length(ci)); pairs <- matrix(NA_integer_, 0, 2)
  for (i in si) {
    dist <- abs(lp[ci] - lp[i]); dist[!avail] <- Inf
    j <- which.min(dist)
    if (length(j) && is.finite(dist[j]) && dist[j] <= cal) { avail[j] <- FALSE; pairs <- rbind(pairs, c(i, ci[j])) }
  }
  pairs
}

# ---- IPCW for censoring at add-on / switch (sensitivity analysis, amendment A-007) ----------------------------------
# Censoring hazard from an aggregated pooled logistic model on cells (arm x age group x sex): logit h = ns(day) + arm + age group + sex.
# Stabilized multiplier by day for each cell = S_numerator(arm, day) / S_denominator(cell, day), numerator model has arm and time only.
ipcw_multipliers <- function(cday, cevent, arm, agegrp, sex, horizon, df_t = 3) {
  cell <- interaction(arm, agegrp, sex, drop = TRUE, sep = "|")
  t <- pmin(cday, horizon); e <- cevent & cday <= horizon
  rows <- do.call(rbind, lapply(levels(cell), function(cl) {
    sel <- cell == cl
    cbind(cell = cl, arm = arm[sel][1], agegrp = as.character(agegrp[sel][1]), sex = as.character(sex[sel][1]), day = seq_len(horizon),
          ev = wsum_by_time(t[sel & e], rep(1, sum(sel & e)), horizon), risk = rev(cumsum(rev(wsum_by_time(t[sel], rep(1, sum(sel)), horizon)))))
  }))
  d <- as.data.frame(rows, stringsAsFactors = FALSE); d$day <- as.integer(d$day); d$ev <- as.numeric(d$ev); d$risk <- as.numeric(d$risk); d$arm <- as.integer(d$arm)
  fit_d <- suppressWarnings(glm(cbind(ev, risk - ev) ~ ns(day, df = df_t) + arm + agegrp + sex, family = quasibinomial(), data = d[d$risk > 0, ]))
  fit_n <- suppressWarnings(glm(cbind(ev, risk - ev) ~ ns(day, df = df_t) + arm, family = quasibinomial(), data = d[d$risk > 0, ]))
  d$h_den <- as.numeric(predict(fit_d, newdata = d, type = "response")); d$h_num <- as.numeric(predict(fit_n, newdata = d, type = "response"))
  d <- d[order(d$cell, d$day), ]
  d$s_den <- ave(1 - d$h_den, d$cell, FUN = cumprod); d$s_num <- ave(1 - d$h_num, d$cell, FUN = cumprod)
  d$mult <- d$s_num / d$s_den
  cw <- matrix(1, horizon, length(levels(cell))); colnames(cw) <- levels(cell)
  for (cl in levels(cell)) cw[, cl] <- d$mult[d$cell == cl][order(d$day[d$cell == cl])]
  list(cell = as.integer(cell), cw = cw)
}

# ---- bootstrap -----------------------------------------------------------------------------------------------------------
# `estimator(dat)` returns list(scalars = named numeric vector, curve = numeric vector). Individuals are resampled with replacement.
bootstrap <- function(dat, estimator, B = 500, seed = 20261020) {
  set.seed(seed); n <- nrow(dat)
  pt <- estimator(dat)
  reps <- lapply(seq_len(B), function(b) { idx <- sample.int(n, n, replace = TRUE); tryCatch(estimator(dat[idx, , drop = FALSE]), error = function(e) NULL) })
  ok <- !vapply(reps, is.null, TRUE)
  S <- do.call(rbind, lapply(reps[ok], `[[`, "scalars")); C <- if (!is.null(pt$curve)) do.call(rbind, lapply(reps[ok], `[[`, "curve")) else NULL
  ci <- t(apply(S, 2, quantile, probs = c(0.025, 0.975), na.rm = TRUE)); colnames(ci) <- c("lo", "hi")
  list(point = pt, ci = cbind(estimate = pt$scalars, ci), curve_ci = if (!is.null(C)) apply(C, 2, quantile, probs = c(0.025, 0.975), na.rm = TRUE) else NULL, n_ok = sum(ok), B = B)
}

# ---- IPCW for loss of Part A/B/D entitlement (sensitivity analysis, primary ITT outcome) -------------------------------
# Discrete-time censoring model on person-months (30-day intervals) with baseline covariates: logit h = interval + arm + covariates.
# Numerator model: interval + arm. Returns an n x horizon matrix of stabilized multipliers S_num(arm, t) / S_den(person, t), constant within each interval.
ipcw_person_month <- function(dat, cday, cevent, covars, horizon, width = 30L, arm = "arm_acei") {
  n <- nrow(dat); t <- pmin(cday, horizon); e <- cevent & cday <= horizon
  K <- ceiling(horizon / width); nk <- pmin(ceiling(t / width), K)
  pid <- rep(seq_len(n), nk); k <- sequence(nk)
  pm <- cbind(dat[pid, c(arm, covars), drop = FALSE], k = factor(k, levels = seq_len(K)), y = as.integer(e[pid] & k == nk[pid]))
  fit_d <- suppressWarnings(glm(as.formula(paste("y ~ k +", paste(c(arm, covars), collapse = " + "))), family = binomial(), data = pm))
  fit_n <- suppressWarnings(glm(as.formula(paste("y ~ k +", arm)), family = binomial(), data = pm))
  grid <- cbind(dat[rep(seq_len(n), each = K), c(arm, covars), drop = FALSE], k = factor(rep(seq_len(K), n), levels = seq_len(K)))
  surv <- function(fit) t(apply(1 - matrix(predict(fit, newdata = grid, type = "response"), n, K, byrow = TRUE), 1, cumprod))
  mult <- surv(fit_n) / surv(fit_d)
  mult[, pmin(ceiling(seq_len(horizon) / width), K), drop = FALSE]
}

# Weighted events and at-risk mass per day and arm with person-specific time-varying multipliers M (n x horizon); same output as agg_counts.
agg_counts_person <- function(time, event, w, arm, horizon, M) {
  stopifnot(all(time >= 1), nrow(M) == length(time), ncol(M) == horizon)
  t <- pmin(time, horizon); e <- event & time <= horizon
  bind_rows(lapply(c(0, 1), function(a) {
    s <- which(arm == a); W <- w[s] * M[s, , drop = FALSE]; ts <- t[s]
    risk <- colSums(W * outer(ts, seq_len(horizon), ">="))
    ev <- numeric(horizon); id <- which(e[s]); if (length(id)) { v <- tapply(W[cbind(id, ts[id])], ts[id], sum); ev[as.integer(names(v))] <- v }
    tibble::tibble(day = seq_len(horizon), arm = a, ev = ev, risk = risk)
  }))
}
