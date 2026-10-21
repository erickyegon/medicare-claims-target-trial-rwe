# Step 01: load the pipe-delimited CMS synthetic files into DuckDB with proper types.
# Everything is read as VARCHAR first (keeps leading zeros in NDC/ZIP/codes), then dates
# (DD-Mon-YYYY) and numeric measures are converted; all code fields stay character.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))

DATE_COL <- "(_DT$|^COVSTART$|^REV_CNTR_DT$|_DT_|^PD_DT$)"
NUM_COL  <- "(_AMT$|_MONS$|^QTY_DSPNSD_NUM$|^DAYS_SUPLY_NUM$|^AGE_AT_END_REF_YR$|^FILL_NUM$|^UTLZTN_DAY_CNT$)"

TYPING_CHECK_PATH <- file.path(PROJ_ROOT, "qc", "typing_check.csv")

# For every converted column: non-empty raw values must equal non-missing parsed values.
# A mismatch means a value was silently turned into NA by the conversion -> fail loudly.
typing_check <- function(con, table, raw_tbl, cols, n_rows, out = TYPING_CHECK_PATH) {
  cnt <- function(tbl) unlist(dbGetQuery(con, sprintf("SELECT %s FROM %s",
    paste(sprintf('count("%s") AS "%s"', cols, cols), collapse = ", "), tbl)))
  res <- data.frame(table = table, column = cols, raw_nonempty = as.numeric(cnt(raw_tbl)),
                    parsed_nonmissing = as.numeric(cnt(table)), row.names = NULL)
  res$mismatch <- res$raw_nonempty != res$parsed_nonmissing
  dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)
  write.table(res, out, sep = ",", row.names = FALSE, qmethod = "double",
              col.names = !file.exists(out), append = file.exists(out))
  bad <- res[res$mismatch, ]
  log_step("01_ingest", sprintf("%s typing check: %d converted columns, %d mismatches", table, nrow(res), nrow(bad)), n_rows, n_rows)
  if (nrow(bad) > 0) stop(sprintf("%s: conversion lost values in: %s", table,
    paste(sprintf("%s (%d raw vs %d parsed)", bad$column, bad$raw_nonempty, bad$parsed_nonmissing), collapse = "; ")))
  invisible(res)
}

ingest_file <- function(con, table, glob) {
  tmp <- paste0("raw_", table)
  dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE %s AS SELECT * FROM read_csv('%s', delim='|', header=true,
                          all_varchar=true, filename=false, sample_size=-1)", tmp, glob))
  cols <- dbGetQuery(con, sprintf("DESCRIBE %s", tmp))$column_name
  dcols <- grep(DATE_COL, cols, value = TRUE); ncols <- setdiff(grep(NUM_COL, cols, value = TRUE), dcols)
  repl <- c(sprintf("TRY_STRPTIME(%1$s, '%%d-%%b-%%Y')::DATE AS %1$s", dcols),
            sprintf("TRY_CAST(%1$s AS DOUBLE) AS %1$s", ncols))
  dbExecute(con, sprintf("CREATE OR REPLACE TABLE %s AS SELECT * REPLACE (%s) FROM %s", table, paste(repl, collapse = ", "), tmp))
  n <- dbGetQuery(con, sprintf("SELECT count(*) FROM %s", table))[[1]]
  typing_check(con, table, tmp, c(dcols, ncols), n)
  log_step("01_ingest", sprintf("%s loaded (%d date cols, %d numeric cols typed)", table, length(dcols), length(ncols)), n, n)
  n
}

run_ingest <- function(raw_dir = file.path(PROJ_ROOT, "data", "raw")) {
  unlink(TYPING_CHECK_PATH)
  con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  files <- c(bene = "beneficiary_20*.csv", carrier = "carrier/carrier.csv", outpatient = "outpatient/outpatient.csv",
             inpatient = "inpatient.csv", pde = "pde.csv", hospice = "hospice.csv")
  for (t in names(files)) ingest_file(con, t, file.path(raw_dir, files[[t]]))
  invisible(TRUE)
}
if (sys.nframe() == 0) run_ingest()
