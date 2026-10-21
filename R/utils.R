# Shared helpers: DuckDB connection, step logging.
suppressPackageStartupMessages({library(DBI); library(duckdb)})

find_root <- function(d = getwd()) {  # walk up to the folder holding .project-root
  while (!file.exists(file.path(d, ".project-root"))) { p <- dirname(d); if (p == d) stop("project root not found"); d <- p }
  normalizePath(d)
}
PROJ_ROOT <- find_root()
DB_PATH   <- file.path(PROJ_ROOT, "data", "medicare.duckdb")
LOG_PATH  <- file.path(PROJ_ROOT, "qc", "step_log.tsv")

connect_db <- function(path = DB_PATH, read_only = FALSE) dbConnect(duckdb(), path, read_only = read_only)

# Append one row to the step log (rows in / out of every pipeline step) and echo it.
log_step <- function(step, description, n_in = NA_integer_, n_out = NA_integer_, log_path = LOG_PATH) {
  if (isFALSE(getOption("rwe.log", TRUE))) return(invisible(NULL))   # unit tests switch logging off
  row <- data.frame(time = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), step = step,
                    description = description, n_in = n_in, n_out = n_out)
  dir.create(dirname(log_path), showWarnings = FALSE, recursive = TRUE)
  write.table(row, log_path, sep = "\t", quote = FALSE, row.names = FALSE,
              col.names = !file.exists(log_path), append = file.exists(log_path))
  message(sprintf("[%s] %s | in=%s out=%s", step, description, n_in, n_out))
  invisible(row)
}

# Run a .sql file from sql/ (statements separated by semicolons; -- comment lines are dropped first).
run_sql_file <- function(con, file, dir = file.path(PROJ_ROOT, "sql")) {
  lines <- readLines(file.path(dir, file))
  sql <- paste(lines[!startsWith(trimws(lines), "--")], collapse = "
")
  for (st in Filter(nzchar, trimws(strsplit(sql, ";", fixed = TRUE)[[1]]))) dbExecute(con, st)
  invisible(TRUE)
}
