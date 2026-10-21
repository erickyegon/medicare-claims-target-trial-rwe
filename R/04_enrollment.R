# Step 04: monthly entitlement table and continuous A+B+D spans (sql/enrollment_spans.sql).
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))

# TRUE if the person has A+B+D in every month from the month containing (date - lookback_days) through the month containing `date`.
# SQL predicate over an enroll_span alias `s` and a date expression; kept as one definition so every step uses the same rule.
continuous_abd_sql <- function(bene_expr, date_expr, lookback_days = 365, span_alias = "s")
  sprintf("EXISTS (SELECT 1 FROM enroll_span %1$s WHERE %1$s.BENE_ID = %2$s AND %1$s.span_start <= date_trunc('month', CAST(%3$s AS DATE) - INTERVAL %4$d DAY) AND %1$s.span_end >= CAST(%3$s AS DATE))",
          span_alias, bene_expr, date_expr, as.integer(lookback_days))

build_enrollment <- function(con) {
  run_sql_file(con, "enrollment_spans.sql")
  n_b <- dbGetQuery(con, "SELECT count(*) FROM bene")[[1]]
  em <- dbGetQuery(con, "SELECT count(*) AS n, sum(part_a::INT) AS a, sum(part_b::INT) AS b, sum(part_d::INT) AS d, sum((part_a AND part_b AND part_d)::INT) AS abd FROM enroll_month")
  sp <- dbGetQuery(con, "SELECT count(*) AS spans, count(DISTINCT BENE_ID) AS benes, max(n_months) AS longest FROM enroll_span")
  log_step("04_enrollment", sprintf("enroll_month: %d person-months (A %d, B %d, D %d, A+B+D %d)", em$n, em$a, em$b, em$d, em$abd), n_b * 12, em$n)
  log_step("04_enrollment", sprintf("enroll_span: %d spans for %d beneficiaries (longest %d months)", sp$spans, sp$benes, sp$longest), em$abd, sp$spans)
  invisible(list(month = em, span = sp))
}
run_enrollment <- function() { con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE)); build_enrollment(con) }
if (sys.nframe() == 0) print(run_enrollment())
