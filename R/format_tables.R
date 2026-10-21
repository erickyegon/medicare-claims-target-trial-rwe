# Shared table formatting for the documents and the TFLs:
#   integer counts with thousands separators, shares (columns whose name contains pct / percent / share / %) as percentages,
#   other numbers with the fewest decimals that show them exactly (up to 3), and every NA shown as an en dash.
# Used by docs/_helpers.R, qc/*.qmd and R/11_tfl.R. Machine-readable CSVs keep raw numbers and blank (not "NA") missing values.
EN_DASH <- "–"
.is_share_col <- function(nm) grepl("pct|percent|share|%", nm, ignore.case = TRUE)
.no_sep_col <- function(nm) grepl("^(year|step|day|days|horizon|rank|rk|df)$|_year$|^idx_year$", nm, ignore.case = TRUE)
.decimals <- function(x) { x <- x[!is.na(x)]; for (d in 0:3) if (all(abs(x * 10^d - round(x * 10^d)) < 1e-8)) return(d); 3 }

format_table <- function(df) {
  out <- as.data.frame(df, stringsAsFactors = FALSE)
  for (nm in names(out)) {
    x <- out[[nm]]
    if (is.numeric(x)) {
      d <- .decimals(x)
      s <- if (.is_share_col(nm)) paste0(formatC(x, format = "f", digits = max(d, 1), big.mark = ","), "%")
           else if (d == 0 && .no_sep_col(nm)) as.character(round(x))
           else formatC(x, format = "f", digits = d, big.mark = ",")
      s[is.na(x)] <- EN_DASH; out[[nm]] <- s
    } else if (is.logical(x)) { s <- ifelse(x, "yes", "no"); s[is.na(x)] <- EN_DASH; out[[nm]] <- s
    } else { x <- as.character(x); x[is.na(x) | x == "NA"] <- EN_DASH; out[[nm]] <- x }
  }
  out
}
# right-align the columns that were numeric before formatting
table_align <- function(df) ifelse(vapply(df, is.numeric, TRUE), "r", "l")
