# Shared helpers for the Quarto documents. Documents read aggregate CSVs only (never the raw data or the database), so they render in CI.
suppressPackageStartupMessages({library(knitr); library(dplyr); library(tidyr); library(readr)})
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
S <- function(...) read_csv(file.path(.root, ...), show_col_types = FALSE, progress = FALSE)
source(file.path(.root, "R", "format_tables.R"))   # integers with thousands separators, shares as %, NA as an en dash
kt <- function(x, ...) kable(format_table(x), align = table_align(x), ...)
fmt <- function(x) format(x, big.mark = ",", trim = TRUE)
ci <- function(e, lo, hi, scale = 100, d = 1) sprintf("%.*f (95%% CI %.*f to %.*f)", d, scale * e, d, scale * lo, d, scale * hi)
dataset_version <- function() trimws(readLines(file.path(.root, "qc", "dataset_version.txt"))[1])
trunc_chr <- function(x, n) ifelse(nchar(x) > n, paste0(substr(x, 1, n - 1), "..."), x)
# narrative helper: states whether every interval in a set includes a value, so prose can never contradict the table
all_include <- function(lo, hi, v = 1) all(lo <= v & hi >= v)
n_excluding <- function(lo, hi, v = 1) sum(!(lo <= v & hi >= v))
