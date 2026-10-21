# Step 03: build versioned code lists (each with source + date columns) and report PDE match counts.
#   Inputs (data/ref/, downloaded 2026-10-20): FDA NDC Directory (ndctext.zip), ICD-10-CM FY2023 order file (CMS).
#   CCW lists come from codelists/build/extract_ccw.py. Outputs: codelists/*.csv, qc/ndc_match_*.csv
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(stringr); library(readr); library(tidyr)})
REF <- file.path(PROJ_ROOT, "data", "ref"); CL <- file.path(PROJ_ROOT, "codelists")
DOWNLOAD_DATE <- "2026-10-20"

# ---- ICD-10-CM (FY2023, CMS) ------------------------------------------------------------
read_icd10cm <- function(path = file.path(REF, "icd10cm", "icd10cm_order_2023.txt")) {
  x <- readLines(path, encoding = "latin1")
  tibble(code = str_trim(substr(x, 7, 13)), billable = substr(x, 15, 15) == "1", description = str_trim(substr(x, 78, 400)))
}
# All billable ICD-10-CM codes starting with any prefix; `keep` optionally filters the expanded rows.
expand_icd <- function(icd, prefixes, role, family, keep = function(d) d) {
  out <- bind_rows(lapply(prefixes, function(p) icd %>% filter(startsWith(code, p), billable))) %>% keep()
  out %>% transmute(role = role, family = family, icd10_code = code, description,
                    source = "ICD-10-CM FY2023 code table (cms.gov 2023-code-descriptions-tabular-order.zip)", download_date = DOWNLOAD_DATE)
}
build_icd_lists <- function() {
  icd <- read_icd10cm()
  bronch <- expand_icd(icd, "J20", "index_event", "acute bronchitis (J20.x)")
  excl <- bind_rows(
    expand_icd(icd, paste0("J", 12:18), "exclusion_pneumonia_30d;outcome_pneumonia", "pneumonia (J12-J18)"),
    expand_icd(icd, "J01", "exclusion_other_abx_dx_index_day", "sinusitis (J01)"),
    expand_icd(icd, c("J02", "J03"), "exclusion_other_abx_dx_index_day", "pharyngitis/tonsillitis (J02, J03)"),
    expand_icd(icd, c("H65", "H66"), "exclusion_other_abx_dx_index_day", "otitis media (H65, H66)"),
    expand_icd(icd, "N390", "exclusion_other_abx_dx_index_day", "urinary tract infection (N39.0)"),
    expand_icd(icd, "L03", "exclusion_other_abx_dx_index_day", "skin infection (L03)"),
    # negative control: femur/hip fracture, initial encounter only (7th character A, B, C)
    # The synthetic claims carry S72 codes WITHOUT the 7th character (only S72009 occurs), so each initial-encounter code is listed both
    # with its 7th character and as its 6-character parent (amendment A-006).
    expand_icd(icd, "S72", "negative_control_outcome", "femur fracture incl. hip, initial encounter (S72, 7th char A/B/C)",
               keep = function(d) d %>% filter(str_sub(code, -1) %in% c("A", "B", "C")) %>% (function(x) bind_rows(x, x %>% mutate(code = str_sub(code, 1, -2)))) %>% distinct(code, .keep_all = TRUE)))
  excl <- distinct(excl)
  write_csv(bronch, file.path(CL, "icd10_bronchitis.csv")); write_csv(excl, file.path(CL, "icd10_exclusions.csv"))
  log_step("03_codelists", "icd10_bronchitis.csv / icd10_exclusions.csv written", nrow(bronch), nrow(excl))
  list(bronchitis = bronch, exclusions = excl)
}

# ---- Revenue centers for ED (documented even though absent from the data; see amendment A-001) ----
build_revenue_ed <- function() {
  rc <- tibble(revenue_center = c(sprintf("%04d", 450:459), "0981"),
               description = c("Emergency room - general", "Emergency room - EMTALA screening", "Emergency room - beyond EMTALA screening",
                               "Emergency room - urgent care", "Emergency room - fast track", "Emergency room - (reserved)", "Emergency room - (reserved)",
                               "Emergency room - (reserved)", "Emergency room - (reserved)", "Emergency room - other", "Professional fees - emergency room"),
               source = "Revenue codes named in protocol Section 7; descriptions abbreviated and should be checked against the NUBC code set",
               download_date = DOWNLOAD_DATE, populated_in_data = FALSE)
  write_csv(rc, file.path(CL, "revenue_center_ed.csv")); rc
}

# ---- Antibiotic NDCs from the FDA NDC Directory -----------------------------------------
ANTIBIOTIC_RULES <- tribble(
  ~generic, ~class, ~key,   # canonical substance key (after salt/hydrate stripping) must equal exactly this
  "amoxicillin", "penicillin", "AMOXICILLIN",
  "amoxicillin-clavulanate", "penicillin", "AMOXICILLIN|CLAVULANATE",
  "azithromycin", "macrolide", "AZITHROMYCIN",
  "clarithromycin", "macrolide", "CLARITHROMYCIN",
  "doxycycline", "tetracycline", "DOXYCYCLINE",
  "cephalexin", "cephalosporin", "CEPHALEXIN",
  "cefuroxime axetil", "cephalosporin", "CEFUROXIME",
  "cefdinir", "cephalosporin", "CEFDINIR",
  "cefpodoxime", "cephalosporin", "CEFPODOXIME",
  "levofloxacin", "fluoroquinolone", "LEVOFLOXACIN",
  "moxifloxacin", "fluoroquinolone", "MOXIFLOXACIN",
  "sulfamethoxazole-trimethoprim", "sulfonamide", "SULFAMETHOXAZOLE|TRIMETHOPRIM")

# Reduce a SUBSTANCENAME like "AZITHROMYCIN DIHYDRATE" or "CLAVULANIC ACID; AMOXICILLIN" to a canonical sorted key.
substance_key <- function(s) {
  if (is.na(s)) return("")
  parts <- str_trim(str_split(toupper(s), ";")[[1]])
  parts <- parts[parts != "AMOXICILLIN SODIUM"]                     # IV salt that appears in a few combination listings
  parts <- str_replace(parts, "^CLAVULANIC ACID$|^CLAVULANATE POTASSIUM$", "CLAVULANATE")
  parts <- str_replace(parts, " (HYDROCHLORIDE MONOHYDRATE|DIHYDRATE|MONOHYDRATE|HYCLATE|ANHYDROUS|HYDROCHLORIDE|PROXETIL|AXETIL)$", "")
  paste(sort(unique(parts)), collapse = "|")
}
normalize_ndc11 <- function(pkg) {   # "0002-0152-01" (4-4-2), "50580-045-10" (5-3-2), "12345-6789-1" (5-4-1) -> 11 digits
  p <- str_split_fixed(pkg, "-", 3)
  paste0(str_pad(p[, 1], 5, pad = "0"), str_pad(p[, 2], 4, pad = "0"), str_pad(p[, 3], 2, pad = "0"))
}
read_ndc_table <- function(f) read_tsv(file.path(REF, "ndc", f), col_types = cols(.default = "c"), locale = locale(encoding = "latin1"))

build_ndc_list <- function() {
  prod <- read_ndc_table("product.txt"); pkg <- read_ndc_table("package.txt")
  prod$skey <- vapply(prod$SUBSTANCENAME, substance_key, "")
  sel <- prod %>% filter(coalesce(ROUTENAME, "") == "ORAL", PRODUCTTYPENAME == "HUMAN PRESCRIPTION DRUG",
                         !str_detect(coalesce(DOSAGEFORMNAME, ""), "KIT|INJECTION")) %>%
    inner_join(ANTIBIOTIC_RULES, by = c("skey" = "key"))
  # doxycycline 20 mg is the sub-antimicrobial periodontitis product, not an antibacterial course
  sub_abx <- sel %>% filter(generic == "doxycycline", str_detect(coalesce(ACTIVE_NUMERATOR_STRENGTH, ""), "^20(\\.0+)?$"))
  sel <- anti_join(sel, sub_abx, by = "PRODUCTID")
  ndc <- sel %>% inner_join(pkg %>% select(PRODUCTID, NDCPACKAGECODE), by = "PRODUCTID") %>%
    transmute(ndc11 = normalize_ndc11(NDCPACKAGECODE), ndc9 = str_sub(ndc11, 1, 9), generic, class, substance_name_raw = SUBSTANCENAME,
              proprietary_name = PROPRIETARYNAME, labeler = LABELERNAME, dosage_form = DOSAGEFORMNAME, route = ROUTENAME,
              strength = paste(ACTIVE_NUMERATOR_STRENGTH, ACTIVE_INGRED_UNIT), marketing_start = STARTMARKETINGDATE, marketing_end = ENDMARKETINGDATE,
              source = "FDA NDC Directory (accessdata.fda.gov/cder/ndctext.zip)", download_date = DOWNLOAD_DATE) %>% distinct()
  stopifnot(nrow(ndc) > 0, all(str_detect(ndc$ndc11, "^[0-9]{11}$")))
  fda_n <- n_distinct(ndc$ndc11)
  # Second source: RxNorm historical NDCs (codelists/build/rxnorm_antibiotic_ndcs.py), needed because the FDA directory lists
  # only currently marketed products while the synthetic PDE uses historical NDCs.
  rx <- read_csv(file.path(REF, "rxnorm_ndcs.csv"), col_types = cols(.default = "c")) %>%
    transmute(ndc11, ndc9 = str_sub(ndc11, 1, 9), generic, class, rxcui, rxnorm_name, rx_start = ndc_start, rx_end = ndc_end)
  comb <- full_join(ndc %>% mutate(in_fda_directory = TRUE), rx %>% mutate(in_rxnorm = TRUE), by = c("ndc11", "generic"), suffix = c("", ".rx")) %>%
    mutate(ndc9 = coalesce(ndc9, ndc9.rx), class = coalesce(class, class.rx), in_fda_directory = coalesce(in_fda_directory, FALSE),
           in_rxnorm = coalesce(in_rxnorm, FALSE), source = case_when(in_fda_directory & in_rxnorm ~ "FDA NDC Directory + RxNorm",
             in_fda_directory ~ "FDA NDC Directory", TRUE ~ "RxNorm (RxNav allhistoricalndcs)"), download_date = DOWNLOAD_DATE) %>%
    select(ndc11, ndc9, generic, class, source, in_fda_directory, in_rxnorm, rxcui, rxnorm_name, rx_start, rx_end, substance_name_raw,
           proprietary_name, labeler, dosage_form, route, strength, marketing_start, marketing_end, download_date) %>%
    group_by(ndc11, generic) %>% slice(1) %>% ungroup()
  conflicts <- comb %>% group_by(ndc11) %>% filter(n_distinct(generic) > 1)
  if (nrow(conflicts) > 0) { print(as.data.frame(conflicts[, c("ndc11", "generic")])); stop("an NDC maps to more than one listed generic") }
  write_csv(comb, file.path(CL, "ndc_antibiotics.csv"))
  log_step("03_codelists", sprintf("ndc_antibiotics.csv: %d NDC-11 (FDA %d; RxNorm %d; %d 20 mg doxycycline products excluded)",
                                    nrow(comb), fda_n, n_distinct(rx$ndc11), nrow(sub_abx)), fda_n + n_distinct(rx$ndc11), nrow(comb))
  comb
}

# ---- Match listed NDCs to PDE ---------------------------------------------------------------
ndc_match_report <- function(ndc) {
  con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
  pde <- dbGetQuery(con, "SELECT PROD_SRVC_ID AS ndc11, BENE_ID FROM pde")
  fills <- pde %>% count(ndc11, name = "fills")
  matched <- pde %>% inner_join(distinct(ndc, ndc11, generic), by = "ndc11")
  by_drug <- ANTIBIOTIC_RULES %>% select(generic, class) %>%
    left_join(ndc %>% group_by(generic) %>% summarise(listed_ndc11 = n_distinct(ndc11), .groups = "drop"), by = "generic") %>%
    left_join(matched %>% group_by(generic) %>% summarise(matched_ndc11 = n_distinct(ndc11), fills = n(), benes = n_distinct(BENE_ID), .groups = "drop"), by = "generic") %>%
    mutate(across(c(listed_ndc11, matched_ndc11, fills, benes), ~ coalesce(.x, 0L)), small_cell_lt11_benes = benes > 0 & benes < 11)
  near <- fills %>% filter(!ndc11 %in% ndc$ndc11) %>% mutate(ndc9 = str_sub(ndc11, 1, 9)) %>%
    inner_join(ndc %>% distinct(ndc9, generic), by = "ndc9") %>% group_by(generic) %>%
    summarise(pde_ndc11_unlisted_but_product_listed = n_distinct(ndc11), fills = sum(fills), .groups = "drop")
  list(by_drug = by_drug, near_miss = near,
       summary = tibble(pde_distinct_ndc = n_distinct(pde$ndc11), listed_ndc11 = n_distinct(ndc$ndc11), matched_ndc11 = n_distinct(matched$ndc11),
                        pde_fills_total = nrow(pde), pde_fills_matched = nrow(matched), pde_benes_total = n_distinct(pde$BENE_ID),
                        pde_benes_with_listed_abx = n_distinct(matched$BENE_ID)))
}

# ---- What does the FDA directory say the PDE NDCs are? (coverage check only; does not extend the list) ----
pde_directory_profile <- function() {
  con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
  pde <- dbGetQuery(con, "SELECT PROD_SRVC_ID AS ndc11, count(*) AS fills FROM pde GROUP BY 1") %>% mutate(fills = as.numeric(fills))
  pkg <- read_ndc_table("package.txt") %>% transmute(PRODUCTID, ndc11 = normalize_ndc11(NDCPACKAGECODE)) %>% distinct()
  prod <- read_ndc_table("product.txt") %>% select(PRODUCTID, SUBSTANCENAME, PHARM_CLASSES, ROUTENAME)
  j <- pde %>% left_join(pkg, by = "ndc11", relationship = "many-to-many") %>% left_join(prod, by = "PRODUCTID")
  abx <- "Antibacterial|Penicillin|Cephalosporin|Macrolide|Quinolone|Tetracycline|Sulfonamide|Lincosamide|Nitrofuran"
  list(found = j %>% summarise(pde_ndc = n_distinct(ndc11), found_in_directory = n_distinct(ndc11[!is.na(PRODUCTID)]),
                               fills_total = sum(fills), fills_found = sum(fills[!is.na(PRODUCTID)])),
       other_antibacterials = j %>% filter(str_detect(coalesce(PHARM_CLASSES, ""), abx), str_detect(coalesce(ROUTENAME, ""), "ORAL")) %>%
         group_by(SUBSTANCENAME) %>% summarise(ndc11 = n_distinct(ndc11), fills = sum(fills), .groups = "drop") %>% arrange(desc(fills)))
}

if (sys.nframe() == 0) {
  build_icd_lists(); build_revenue_ed(); ndc <- build_ndc_list()
  m <- ndc_match_report(ndc); d <- pde_directory_profile(); q <- function(f) file.path(PROJ_ROOT, "qc", f)
  write_csv(m$by_drug, q("ndc_match_by_drug.csv")); write_csv(m$near_miss, q("ndc_match_near_miss.csv")); write_csv(m$summary, q("ndc_match_summary.csv"))
  write_csv(d$found, q("pde_directory_coverage.csv")); write_csv(d$other_antibacterials, q("pde_other_oral_antibacterials.csv"))
  print(as.data.frame(m$summary)); print(as.data.frame(m$by_drug)); print(as.data.frame(m$near_miss)); print(as.data.frame(d$found))
  print(as.data.frame(head(d$other_antibacterials, 25)))
}
