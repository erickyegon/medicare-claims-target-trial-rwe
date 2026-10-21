# Helpers: build small in-memory DuckDB databases with hand-made beneficiaries, then run the SAME R/SQL code as the pipeline.
suppressPackageStartupMessages({library(DBI); library(duckdb); library(dplyr)})
options(rwe.log = FALSE)
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
for (f in c("utils.R", "04_enrollment.R", "06_cohort.R", "07_followup.R")) source(file.path(.root, "R", f), local = FALSE)

d <- function(x) as.Date(x)
months_between <- function(from, to) seq(d(from), d(to), by = "month")

# One beneficiary: part A+B months and part D months (vectors of month-start dates). One row per calendar year with any month.
mk_bene <- function(id, birth, ab_months, d_months) {
  yrs <- sort(unique(as.integer(format(c(ab_months, d_months), "%Y"))))
  rows <- lapply(yrs, function(y) {
    r <- list(BENE_ID = id, BENE_ENROLLMT_REF_YR = as.character(y), BENE_BIRTH_DT = d(birth), SEX_IDENT_CD = "1")
    for (m in 1:12) {
      ms <- as.Date(sprintf("%d-%02d-01", y, m))
      r[[sprintf("MDCR_ENTLMT_BUYIN_IND_%02d", m)]] <- if (ms %in% ab_months) "3" else "0"
      r[[sprintf("PTD_CNTRCT_ID_%02d", m)]] <- if (ms %in% d_months) "Z0001" else NA_character_
    }
    as.data.frame(r, stringsAsFactors = FALSE)
  })
  bind_rows(rows)
}
new_con <- function() dbConnect(duckdb())
