# Step 09b: sensitivity of the 30-day pooled logistic estimate to the spline degrees of freedom (A-014). Point estimates only (no bootstrap), from the
# person-level weights and follow-up that 09_analysis.R left in the database. Compares the model fitted to days 1-30 with 2, 3 and 4 df against the
# 365-day model read at day 30 and against weighted KM. Writes aggregate-only qc/analysis/pooled30_df_check.csv.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R")); source(file.path(.root, "R", "09_analysis_functions.R"))
suppressPackageStartupMessages({library(dplyr); library(readr); library(DBI)})
con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
d <- dbGetQuery(con, "SELECT a.arm_acei, a.w, f.idx, f.itt_end, f.first_adm FROM analysis_primary a JOIN fu_primary f USING (BENE_ID)") %>%
  mutate(event = !is.na(first_adm) & first_adm <= itt_end, time = as.numeric(ifelse(event, first_adm - idx, itt_end - idx)))
stopifnot(nrow(d) == 790, all(d$time >= 1))
agg <- agg_counts(d$time, d$event, d$w, d$arm_acei, 365L)
row <- function(model, df, rk) { v <- risks_at(rk, 30); tibble::tibble(model = model, spline_df = df, risk_acei = v[["risk_acei"]], risk_thiazide = v[["risk_thiazide"]], rd = v[["rd"]], rr = v[["rr"]]) }
out <- bind_rows(row("weighted KM", NA, risk_km(agg)),
                 row("pooled logistic, 365-day model read at day 30", 4, risk_pooled(agg, 4)),
                 bind_rows(lapply(c(2, 3, 4), function(k) row("pooled logistic, separate model fitted to days 1-30", k, risk_pooled(agg[agg$day <= 30, ], k))))) %>%
  mutate(across(c(risk_acei, risk_thiazide, rd, rr), ~ round(.x, 4)))
write_csv(out, file.path(PROJ_ROOT, "qc", "analysis", "pooled30_df_check.csv")); print(as.data.frame(out))
