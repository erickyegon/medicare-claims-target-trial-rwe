# Step 06a: code lists for the hypertension study (amendment A-005, protocol v0.3).
#   codelists/antihypertensive_ingredients.csv  study-drug and washout ingredients (RxClass/ATC, see codelists/build/rxclass_antihypertensives.py)
#   codelists/icd10_hypertension.csv            I10-I16 (billable ICD-10-CM FY2023 codes)
#   codelists/ndc_antihypertensive.csv          PDE NDCs mapped (RxNorm NDC -> RxCUI -> ingredient) to the antihypertensive classes
#   data/ref/ndc_atc.csv                        PDE NDC -> ATC level-4 class (for the baseline count of distinct drug classes)
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "03_codelists.R"))   # reuses read_icd10cm / expand_icd (definitions only; its main block is guarded)
suppressPackageStartupMessages({library(tidyr)})

build_ahtn_lists <- function() {
  mem <- read_csv(file.path(REF, "rxclass_antihtn_members.csv"), col_types = cols(.default = "c"))
  ingr <- mem %>% mutate(role = case_when(ahtn_class == "ACEI" ~ "study_drug_acei", ahtn_class == "THIAZIDE" ~ "study_drug_thiazide", TRUE ~ "washout_only"),
                         source = "RxClass ATC class members via RxNav (classMembers, ttys=IN)", download_date = retrieved) %>% select(-retrieved)
  # an ingredient could sit in two lists (none expected); stop if the study classes overlap with anything else
  dup <- ingr %>% group_by(ingredient_rxcui) %>% filter(n_distinct(ahtn_class) > 1)
  if (nrow(dup) > 0) { print(as.data.frame(dup)); stop("ingredient appears in more than one antihypertensive class") }
  write_csv(ingr, file.path(CL, "antihypertensive_ingredients.csv"))

  htn <- expand_icd(read_icd10cm(), paste0("I", c(10, 11, 12, 13, 15, 16)), "inclusion_hypertension_baseline", "hypertensive diseases (I10-I16)")
  write_csv(htn, file.path(CL, "icd10_hypertension.csv"))

  res <- read_csv(file.path(REF, "rxnorm_pde_resolution.csv"), col_types = cols(.default = "c")) %>% filter(resolved == "True")
  ndc_rxcui <- res %>% transmute(ndc11, rxcui = rxcuis) %>% separate_rows(rxcui, sep = ";") %>% filter(rxcui != "") %>% distinct()
  rx_ing <- read_csv(file.path(REF, "rxnorm_rxcui_ingredient.csv"), col_types = cols(.default = "c"))
  per_rxcui <- ndc_rxcui %>% inner_join(rx_ing, by = "rxcui", relationship = "many-to-many") %>%
    left_join(ingr %>% select(ingredient_rxcui, ahtn_class), by = "ingredient_rxcui")
  # NDCs whose RxCUIs disagree about the antihypertensive classes (union is used; they are listed for review)
  cls_sets <- per_rxcui %>% group_by(ndc11, rxcui) %>% summarise(s = paste(sort(unique(na.omit(ahtn_class))), collapse = "+"), .groups = "drop")
  disagree <- cls_sets %>% group_by(ndc11) %>% filter(n_distinct(s) > 1) %>% ungroup()
  write_csv(disagree, file.path(PROJ_ROOT, "qc", "ndc_antihtn_class_disagreement.csv"))
  ndc_ahtn <- per_rxcui %>% filter(!is.na(ahtn_class)) %>% group_by(ndc11, ahtn_class) %>%
    summarise(ingredients = paste(sort(unique(ingredient_name)), collapse = " / "), .groups = "drop") %>%
    mutate(source = "RxNorm NDC history (RxNav ndcproperties) + RxClass ATC lists", download_date = "2026-10-20")
  write_csv(ndc_ahtn, file.path(CL, "ndc_antihypertensive.csv"))
  write_csv(distinct(res, ndc11) %>% mutate(source = "RxNorm resolution of PDE NDCs (RxNav ndcproperties)", download_date = "2026-10-20"), file.path(CL, "ndc_resolved.csv"))
  atc <- read_csv(file.path(REF, "rxnorm_rxcui_atc.csv"), col_types = cols(.default = "c"))
  ndc_atc <- ndc_rxcui %>% inner_join(atc, by = "rxcui", relationship = "many-to-many") %>% filter(nchar(atc_id) == 5) %>% distinct(ndc11, atc_id)
  write_csv(ndc_atc, file.path(REF, "ndc_atc.csv"))

  con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
  fills <- dbGetQuery(con, "SELECT PROD_SRVC_ID AS ndc11, BENE_ID FROM pde")
  summ <- ndc_ahtn %>% inner_join(fills, by = "ndc11", relationship = "many-to-many") %>% group_by(ahtn_class) %>%
    summarise(ndcs_matched = n_distinct(ndc11), fills = n(), benes = n_distinct(BENE_ID), .groups = "drop") %>% arrange(desc(fills))
  write_csv(summ, file.path(PROJ_ROOT, "qc", "ahtn_pde_match.csv"))
  log_step("06_codelists_ahtn", sprintf("ingredients %d; I10-I16 codes %d; NDCs mapped %d (%d with disagreeing RxCUIs)", nrow(ingr), nrow(htn), n_distinct(ndc_ahtn$ndc11), n_distinct(disagree$ndc11)), nrow(ndc_rxcui), nrow(ndc_ahtn))
  list(ingredients = ingr, htn = htn, ndc = ndc_ahtn, summary = summ, disagree = disagree)
}
if (sys.nframe() == 0) { r <- build_ahtn_lists(); print(as.data.frame(r$summary)); print(as.data.frame(head(r$disagree, 20))); print(table(r$htn$icd10_code %>% substr(1, 3))) }
