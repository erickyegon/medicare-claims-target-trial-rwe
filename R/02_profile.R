# Step 02: profiling functions used by qc/profiling.qmd (row counts, dates, duplicates,
# impossible dates, per-field missingness, constant fields, ED revenue-center and PDE ID checks).
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))

PROFILE_TABLES <- list(  # table -> natural key (NULL = none documented) and service-date column
  bene = list(key = c("BENE_ID", "BENE_ENROLLMT_REF_YR"), date = "COVSTART"),
  carrier = list(key = "CLM_ID", date = "CLM_FROM_DT"),
  outpatient = list(key = "CLM_ID", date = "CLM_FROM_DT"),
  inpatient = list(key = "CLM_ID", date = "CLM_FROM_DT"),
  pde = list(key = "PDE_ID", date = "SRVC_DT"),
  hospice = list(key = "CLM_ID", date = "CLM_FROM_DT"))
DATA_END <- as.Date("2023-03-31")  # CMS guide: claims run to early March 2023

table_summary <- function(con) {
  do.call(rbind, lapply(names(PROFILE_TABLES), function(t) {
    k <- PROFILE_TABLES[[t]]; d <- k$date; keys <- paste(k$key, collapse = ", ")
    q <- sprintf("SELECT '%s' AS tbl, count(*) AS n_rows, count(DISTINCT (%s)) AS n_distinct_key,
        count(*) - count(DISTINCT (%s)) AS dup_key_rows, count(DISTINCT BENE_ID) AS n_benes,
        min(%s) AS min_date, max(%s) AS max_date FROM %s", t, keys, keys, d, d, t)
    dbGetQuery(con, q)
  }))
}

full_row_dups <- function(con, t) {  # rows that are exact copies of an earlier row
  cols <- dbGetQuery(con, sprintf("DESCRIBE %s", t))$column_name
  dbGetQuery(con, sprintf("SELECT count(*) - count(DISTINCT (%s)) AS n FROM %s",
                          paste(sprintf('"%s"', cols), collapse = ", "), t))$n
}

field_profile <- function(con, t) {
  cols <- dbGetQuery(con, sprintf("DESCRIBE %s", t))[, c("column_name", "column_type")]
  qs <- sprintf("SELECT '%1$s' AS field, '%2$s' AS type, count(*) - count(\"%1$s\") AS n_missing,
                 count(DISTINCT \"%1$s\") AS n_distinct, min(\"%1$s\")::VARCHAR AS min_val, max(\"%1$s\")::VARCHAR AS max_val
                 FROM %3$s", cols$column_name, cols$column_type, t)
  res <- dbGetQuery(con, paste(qs, collapse = " UNION ALL "))
  n <- dbGetQuery(con, sprintf("SELECT count(*) FROM %s", t))[[1]]
  res$pct_missing <- round(100 * res$n_missing / n, 1)
  # identifier-type fields: never publish their minimum or maximum value (they would be real record identifiers)
  # (by name, or any near-unique text field: more than 10% of its non-missing values are distinct, e.g. RX_SRVC_RFRNC_NUM, which duplicates PDE_ID)
  id_like <- grepl("(^|_)ID$|NPI|UPIN", res$field) | (res$type == "VARCHAR" & res$n_distinct > 0.1 * (n - res$n_missing))
  res$min_val[id_like] <- "[redacted: identifier]"; res$max_val[id_like] <- "[redacted: identifier]"
  res$constant <- res$n_distinct == 1 & res$n_missing == 0   # single value on every row
  res$all_missing <- res$n_missing == n
  res$table <- t
  res[order(-res$pct_missing), ]
}

impossible_dates <- function(con) {
  q <- function(label, sql) { r <- dbGetQuery(con, sql); data.frame(check = label, n = r[[1]]) }
  rbind(
    q("carrier: CLM_THRU_DT < CLM_FROM_DT", "SELECT count(*) FROM carrier WHERE CLM_THRU_DT < CLM_FROM_DT"),
    q("outpatient: CLM_THRU_DT < CLM_FROM_DT", "SELECT count(*) FROM outpatient WHERE CLM_THRU_DT < CLM_FROM_DT"),
    q("inpatient: CLM_THRU_DT < CLM_FROM_DT", "SELECT count(*) FROM inpatient WHERE CLM_THRU_DT < CLM_FROM_DT"),
    q("inpatient: admission date > CLM_THRU_DT", "SELECT count(*) FROM inpatient WHERE CLM_ADMSN_DT > CLM_THRU_DT"),
    q("any claim/PDE date before 2015-01-01 or after 2023-03-31", sprintf(
      "SELECT sum(n) FROM (SELECT count(*) n FROM carrier WHERE CLM_FROM_DT NOT BETWEEN DATE '2015-01-01' AND DATE '%1$s'
        UNION ALL SELECT count(*) FROM outpatient WHERE CLM_FROM_DT NOT BETWEEN DATE '2015-01-01' AND DATE '%1$s'
        UNION ALL SELECT count(*) FROM inpatient WHERE CLM_FROM_DT NOT BETWEEN DATE '2015-01-01' AND DATE '%1$s'
        UNION ALL SELECT count(*) FROM pde WHERE SRVC_DT NOT BETWEEN DATE '2015-01-01' AND DATE '%1$s')", DATA_END)),
    q("claims dated before beneficiary birth date (carrier)", "SELECT count(*) FROM carrier c JOIN (SELECT BENE_ID, min(BENE_BIRTH_DT) b FROM bene GROUP BY 1) USING (BENE_ID) WHERE c.CLM_FROM_DT < b"),
    q("PDE fills before beneficiary birth date", "SELECT count(*) FROM pde c JOIN (SELECT BENE_ID, min(BENE_BIRTH_DT) b FROM bene GROUP BY 1) USING (BENE_ID) WHERE c.SRVC_DT < b"),
    q("beneficiaries with >1 distinct birth date across years", "SELECT count(*) FROM (SELECT BENE_ID FROM bene GROUP BY 1 HAVING count(DISTINCT BENE_BIRTH_DT) > 1)"),
    q("claim/PDE BENE_ID not in beneficiary files", "SELECT sum(n) FROM (SELECT count(*) n FROM carrier WHERE BENE_ID NOT IN (SELECT BENE_ID FROM bene) UNION ALL SELECT count(*) FROM outpatient WHERE BENE_ID NOT IN (SELECT BENE_ID FROM bene) UNION ALL SELECT count(*) FROM inpatient WHERE BENE_ID NOT IN (SELECT BENE_ID FROM bene) UNION ALL SELECT count(*) FROM pde WHERE BENE_ID NOT IN (SELECT BENE_ID FROM bene))"))
}

# --- Check 1: are ED revenue center codes 0450-0459 and 0981 populated in outpatient? ---
rev_center_check <- function(con) {
  list(
    overall = dbGetQuery(con, "SELECT count(*) AS outpatient_rows, count(REV_CNTR) AS rev_cntr_populated,
       count(*) FILTER (WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981') AS ed_rev_rows,
       count(DISTINCT CLM_ID) FILTER (WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981') AS ed_claims,
       count(DISTINCT BENE_ID) FILTER (WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981') AS ed_benes FROM outpatient"),
    top = dbGetQuery(con, "SELECT REV_CNTR, count(*) AS n, count(DISTINCT BENE_ID) AS benes FROM outpatient GROUP BY 1 ORDER BY 2 DESC LIMIT 15"),
    by_year = dbGetQuery(con, "SELECT year(CLM_FROM_DT) AS yr, count(DISTINCT CLM_ID) FILTER (WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981') AS ed_claims,
       count(DISTINCT BENE_ID) FILTER (WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981') AS ed_benes FROM outpatient GROUP BY 1 ORDER BY 1"),
    rows_per_claim = dbGetQuery(con, "SELECT rows_per_claim, count(*) AS n_claims FROM (SELECT CLM_ID, count(*) AS rows_per_claim FROM outpatient GROUP BY 1) GROUP BY 1 ORDER BY 1 LIMIT 10"))
}

# --- Check 2: what do PDE product service IDs look like? ---
pde_id_check <- function(con) {
  list(
    format = dbGetQuery(con, "SELECT length(PROD_SRVC_ID) AS len, regexp_matches(PROD_SRVC_ID, '^[0-9]+$') AS all_digits,
       count(*) AS n, count(DISTINCT PROD_SRVC_ID) AS n_distinct, count(*) FILTER (WHERE PROD_SRVC_ID LIKE '0%') AS leading_zero
       FROM pde GROUP BY 1, 2 ORDER BY 3 DESC"),
    examples = dbGetQuery(con, "SELECT PROD_SRVC_ID, count(*) AS n FROM pde GROUP BY 1 ORDER BY 2 DESC LIMIT 8"),
    missing = dbGetQuery(con, "SELECT count(*) - count(PROD_SRVC_ID) AS n_missing FROM pde"))
}
