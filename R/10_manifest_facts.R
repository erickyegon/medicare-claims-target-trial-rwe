# Step 10a: dataset manifest (the "dataset version" quoted in every TFL footnote) and the aggregate feasibility facts used by docs/feasibility.qmd
# and the study report. Reads the database read-only; writes aggregate-only CSVs so the documents can be rendered without the raw data.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(readr)})

digest_string <- function(x) { f <- tempfile(); writeLines(x, f); unname(tools::md5sum(f)) }

build_manifest <- function() {
  files <- c(list.files(file.path(PROJ_ROOT, "data", "raw"), recursive = TRUE, full.names = TRUE), list.files(file.path(PROJ_ROOT, "codelists"), pattern = "\\.csv$", full.names = TRUE))
  m <- tibble::tibble(file = sub(paste0(PROJ_ROOT, "/"), "", normalizePath(files, winslash = "/"), fixed = TRUE), bytes = file.size(files), md5 = unname(tools::md5sum(files)))
  ver <- substr(digest_string(paste(m$file, m$md5, collapse = "|")), 1, 10)
  write_csv(m, file.path(PROJ_ROOT, "qc", "dataset_manifest.csv")); writeLines(ver, file.path(PROJ_ROOT, "qc", "dataset_version.txt"))
  list(manifest = m, version = ver)
}

# Two named measures of PDE fills that cannot be linked to a drug (defined in the README):
#   measure 1, "no RxNorm record": the NDC is not found in RxNorm (RxNav) at all;
#   measure 2, "no RxNorm drug concept": no RxNorm record, or a record that gives no drug (ingredient) concept. It contains measure 1.
feasibility_facts <- function() {
  con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
  q <- function(s) dbGetQuery(con, s)[[1]]
  res <- read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_pde_resolution.csv"), col_types = cols(.default = "c"))
  drugs <- read_csv(file.path(PROJ_ROOT, "data", "ref", "rxnorm_rxcui_drug.csv"), col_types = cols(.default = "c"))
  j20 <- read_csv(file.path(PROJ_ROOT, "qc", "scan", "bronchitis_recheck_classes.csv"), col_types = cols())
  fills <- q("SELECT count(*) FROM pde")
  per_ndc <- dbGetQuery(con, "SELECT PROD_SRVC_ID AS ndc11, count(*) AS n FROM pde GROUP BY 1") %>% mutate(n = as.numeric(n))
  concept_ndc <- dbGetQuery(con, "SELECT DISTINCT ndc11 FROM fill_drug")$ndc11
  no_record <- sum(per_ndc$n[!per_ndc$ndc11 %in% res$ndc11[res$resolved == "True"]])
  no_concept <- sum(per_ndc$n[!per_ndc$ndc11 %in% concept_ndc])
  n_rec <- sum(res$resolved == "True")
  tibble::tibble(
    item = c("beneficiaries (distinct, all years)", "influenza diagnoses (J09-J11), any claim", "drug concepts named oseltamivir among RxNorm-resolved PDE NDCs", "deaths recorded in beneficiary files",
             "outpatient rows with ED revenue centers 0450-0459 or 0981", "distinct values of dual-eligibility months", "PDE fills",
             "PDE fills with no RxNorm record (measure 1)", "PDE fills with no RxNorm drug concept (measure 2)", "distinct PDE NDCs", "distinct PDE NDCs with an RxNorm record",
             "bronchitis episodes (age 65+, 365d A+B+D)", "bronchitis episodes with any antibacterial (ATC J01) class fill on days 0-30", "Part D share of person-months"),
    value = c(q("SELECT count(DISTINCT BENE_ID) FROM bene"), q("SELECT count(*) FROM dx_long WHERE code LIKE 'J09%' OR code LIKE 'J10%' OR code LIKE 'J11%'"), sum(grepl("oseltamivir", drugs$drug_name, ignore.case = TRUE)),
              q("SELECT count(BENE_DEATH_DT) FROM bene"), q("SELECT count(*) FROM outpatient WHERE REV_CNTR BETWEEN '0450' AND '0459' OR REV_CNTR = '0981'"), q("SELECT count(DISTINCT DUAL_ELGBL_MONS) FROM bene"), fills,
              no_record, no_concept, nrow(res), n_rec, j20$n_episodes[1], sum(grepl("^J01", j20$atc_id)), NA),
    share_pct = c(rep(NA, 7), round(100 * no_record / fills, 1), round(100 * no_concept / fills, 1), NA, round(100 * n_rec / nrow(res), 1), NA, NA, round(100 * q("SELECT avg(part_d::INT) FROM enroll_month"), 1)),
    note = c("", "influenza question not estimable (v0.1)", "", "mortality is not an outcome", "ED visits not observable (A-001)", "not usable as a covariate", "",
             "NDC not found in RxNorm; used for the new-user sensitivity cohort", "wider measure (contains measure 1): also NDCs whose record gives no drug; exposure, washout and the scan use fills with a drug concept",
             "", "", "from the indication scan", "bronchitis / antibiotic question not estimable (A-004)", ""))
}

# Refill pattern of the index class in the primary cohort (evidence for amendment A-007)
refill_pattern <- function() {
  con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
  dbGetQuery(con, "WITH f AS (SELECT h.BENE_ID, a.fill_dt, a.days_supply, row_number() OVER (PARTITION BY h.BENE_ID ORDER BY a.fill_dt) AS rn, lag(a.fill_dt) OVER (PARTITION BY h.BENE_ID ORDER BY a.fill_dt) AS prev
                    FROM htn_cohort h JOIN ahtn_fill a ON a.BENE_ID = h.BENE_ID AND a.ahtn_class = h.arm AND a.fill_dt >= h.idx)
                    SELECT (SELECT count(*) FROM htn_cohort) AS cohort_n, count(*) FILTER (WHERE rn = 1) AS with_index_fill, median(days_supply) FILTER (WHERE rn = 1) AS index_days_supply_median,
                           count(*) FILTER (WHERE rn = 2) AS with_second_fill, median(fill_dt - prev) FILTER (WHERE rn = 2) AS median_days_to_second_fill,
                           quantile_cont(fill_dt - prev, 0.25) FILTER (WHERE rn = 2) AS q1_days_to_second_fill, quantile_cont(fill_dt - prev, 0.75) FILTER (WHERE rn = 2) AS q3_days_to_second_fill,
                           count(*) FILTER (WHERE rn = 2 AND fill_dt - prev <= 120) AS second_fill_within_120_days FROM f")
}

if (sys.nframe() == 0) {
  mf <- build_manifest(); message("dataset version: ", mf$version)
  f <- feasibility_facts(); write_csv(f, file.path(PROJ_ROOT, "qc", "feasibility_facts.csv"), na = ""); print(as.data.frame(f))
  rp <- refill_pattern(); write_csv(rp, file.path(PROJ_ROOT, "qc", "cohort", "refill_pattern.csv"), na = ""); print(as.data.frame(rp))
}
