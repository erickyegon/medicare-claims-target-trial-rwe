# Step 05: systematic feasibility scan to find an indication/exposure the synthetic data actually model.
# Aggregate outputs only -> qc/scan/*.csv, rendered by qc/indication_scan.qmd. Nothing here changes the protocol or code lists.
#   population : age >= 65 and 365 days continuous Part A+B+D before the event (enrollment spans, step 04)
#   has_drug_concept fill : PDE NDC resolved by RxNorm to a drug (see qc/profiling_notes.md)
#   candidates (ranking rule fixed before looking at results): top 5 per list by the smaller arm size, at most 2 per diagnosis/condition
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
suppressPackageStartupMessages({library(dplyr); library(readr); library(stringr); library(tidyr)})
OUT <- file.path(PROJ_ROOT, "qc", "scan"); dir.create(OUT, showWarnings = FALSE)
REF <- file.path(PROJ_ROOT, "data", "ref")
DATA_END <- as.Date("2023-03-02")            # last claim date in the files
MIN_CELL <- 11
write_out <- function(x, f) { write_csv(x, file.path(OUT, f)); invisible(x) }
flag <- function(n) ifelse(is.na(n), NA, n < MIN_CELL)

run_sql_file <- function(con, f) {
  lines <- readLines(file.path(PROJ_ROOT, "sql", f)); sql <- paste(lines[!startsWith(trimws(lines), "--")], collapse = "\n")
  for (st in Filter(nzchar, trimws(strsplit(sql, ";", fixed = TRUE)[[1]]))) dbExecute(con, st)
}

con <- connect_db(); on.exit(dbDisconnect(con, shutdown = TRUE))

# ---- lookup tables from the RxNorm / CCW / ICD reference files --------------------------------------------
res <- read_csv(file.path(REF, "rxnorm_pde_resolution.csv"), col_types = cols(.default = "c")) %>% filter(resolved == "True")
ndc_rxcui <- res %>% transmute(ndc11, rxcui = rxcuis) %>% separate_rows(rxcui, sep = ";") %>% filter(rxcui != "") %>% distinct()
rx_drug <- read_csv(file.path(REF, "rxnorm_rxcui_drug.csv"), col_types = cols(.default = "c"))
rx_atc  <- read_csv(file.path(REF, "rxnorm_rxcui_atc.csv"), col_types = cols(.default = "c"))
ccw_all <- read_csv(file.path(REF, "ccw_all_conditions.csv"), col_types = cols(.default = "c"))
icd <- readLines(file.path(REF, "icd10cm", "icd10cm_order_2023.txt"), encoding = "latin1")
icd3 <- tibble(dx3 = str_trim(substr(icd, 7, 13)), description = str_trim(substr(icd, 78, 400))) %>% filter(nchar(dx3) == 3)
abx_list <- read_csv(file.path(PROJ_ROOT, "codelists", "ndc_antibiotics.csv"), col_types = cols(.default = "c")) %>% select(ndc11, generic)
for (nm in c("ndc_rxcui", "rx_drug", "rx_atc", "ccw_all", "icd3", "abx_list")) duckdb_register(con, nm, get(nm))
run_sql_file(con, "scan_prep.sql")
q <- function(s) dbGetQuery(con, s)
cnt <- function(t) q(sprintf("SELECT count(*) AS n FROM %s", t))$n
log_step("05_scan", sprintf("lookups: dx_long %d rows, fill_drug %d, fill_class %d, dx_cond %d", cnt("dx_long"), cnt("fill_drug"), cnt("fill_class"), cnt("dx_cond")), cnt("fill"), cnt("fill_drug"))
ndc_multi <- q("SELECT count(*) AS n FROM (SELECT ndc11 FROM fill_drug GROUP BY ndc11 HAVING count(DISTINCT drug_name) > 1)")$n
message("NDCs whose RxCUIs map to more than one drug name: ", ndc_multi)

# ---- 1. acute conditions --------------------------------------------------------------------------------
run_sql_file(con, "scan_acute.sql")
log_step("05_scan", "acute: first eligible episodes (age>=65, 365d A+B+D) -> 3-char codes with >= 300", cnt("acute_ep"), cnt("acute_codes"))
win <- q("SELECT dx3, count(*) AS n_episodes,
   count(*) FILTER (WHERE drug02) AS with_drug_0_2, count(*) FILTER (WHERE NOT drug02 AND nodrug02) AS no_drug_only_0_2, count(*) FILTER (WHERE NOT drug02 AND NOT nodrug02) AS nofill_0_2,
   count(*) FILTER (WHERE drug07) AS with_drug_0_7, count(*) FILTER (WHERE NOT drug07 AND nodrug07) AS no_drug_only_0_7, count(*) FILTER (WHERE NOT drug07 AND NOT nodrug07) AS nofill_0_7
   FROM acute_win GROUP BY 1")
top_str <- function(win_label) q("SELECT * FROM acute_top") %>% filter(win == win_label) %>% arrange(dx3, rk) %>%
  mutate(txt = sprintf("%s (%s)", drug_name, ifelse(n < MIN_CELL, "<11", n))) %>% group_by(dx3) %>% summarise(top = paste(txt, collapse = "; "), .groups = "drop")
acute <- win %>% left_join(icd3, by = "dx3") %>%
  left_join(top_str("0-2") %>% rename(top5_drugs_0_2 = top), by = "dx3") %>% left_join(top_str("0-7") %>% rename(top5_drugs_0_7 = top), by = "dx3") %>%
  mutate(pct_with_drug_0_2 = round(100 * with_drug_0_2 / n_episodes, 1), pct_with_drug_0_7 = round(100 * with_drug_0_7 / n_episodes, 1)) %>%
  select(dx3, description, n_episodes, with_drug_0_2, pct_with_drug_0_2, no_drug_only_0_2, nofill_0_2, with_drug_0_7, pct_with_drug_0_7, no_drug_only_0_7, nofill_0_7, top5_drugs_0_2, top5_drugs_0_7) %>%
  arrange(desc(n_episodes)) %>%
  mutate(flag_lt11 = (with_drug_0_2 < MIN_CELL) | (no_drug_only_0_2 < MIN_CELL) | (nofill_0_2 < MIN_CELL) | (with_drug_0_7 < MIN_CELL) | (no_drug_only_0_7 < MIN_CELL) | (nofill_0_7 < MIN_CELL))
write_out(acute, "acute_scan.csv")
# enrichment = share treated with the class in this diagnosis / share treated with the class over all scanned episodes (background use of the drug)
acute_class <- q("SELECT * FROM acute_class") %>% group_by(atc_id) %>% mutate(pooled_share = sum(n_treated) / sum(n_episodes)) %>% ungroup() %>%
  mutate(treated_share = n_treated / n_episodes, enrichment = round(treated_share / pooled_share, 1)) %>%
  left_join(icd3, by = "dx3") %>% rename(dx_description = description) %>% arrange(desc(min_arm))
write_out(acute_class %>% filter(n_treated >= MIN_CELL) %>% mutate(flag_lt11 = n_untreated < MIN_CELL | n_late < MIN_CELL), "acute_class_arms.csv")

# ---- 2. chronic new users -------------------------------------------------------------------------------
run_sql_file(con, "scan_chronic.sql")
log_step("05_scan", "chronic: new users by ATC4 class (age>=65, 365d A+B+D); then by condition", cnt("nu"), cnt("nu_cond"))
atc_names <- rx_atc %>% distinct(atc_id, atc_name)
cond_class <- q("SELECT * FROM cond_class") %>% left_join(atc_names, by = "atc_id") %>% arrange(cond, desc(n_new_users))
write_out(cond_class, "chronic_condition_classes.csv")
pairs <- q("SELECT * FROM pair_arms") %>% left_join(atc_names %>% rename(a_name = atc_name), by = c("a_cls" = "atc_id")) %>%
  left_join(atc_names %>% rename(b_name = atc_name), by = c("b_cls" = "atc_id")) %>% arrange(desc(min_arm)) %>%
  mutate(overlap = round(pmax(n_a_with_b / n_a, n_b_with_a / n_b), 2), flag_lt11 = n_a < MIN_CELL | n_b < MIN_CELL)
write_out(pairs, "chronic_pairs.csv")

# ---- 3. trace the antibiotics that exist -----------------------------------------------------------------
run_sql_file(con, "scan_trace.sql")
tf <- q("SELECT drug_name, count(*) AS fills, count(DISTINCT BENE_ID) AS benes FROM trace_fills GROUP BY 1")
td <- q("SELECT drug_name, count(DISTINCT (BENE_ID, fill_dt, ndc11)) AS fills_with_dx, count(DISTINCT BENE_ID) AS benes_with_dx FROM trace_dx GROUP BY 1")
trace_sum <- tf %>% left_join(td, by = "drug_name") %>% mutate(across(c(fills_with_dx, benes_with_dx), ~ coalesce(.x, 0)), fills_no_dx_in_7d = fills - fills_with_dx)
trace_sum$listed_ndc_fills <- vapply(c("amoxicillin-clavulanate", "moxifloxacin")[match(trace_sum$drug_name, c("amoxicillin / clavulanate", "moxifloxacin"))],
  function(g) q(sprintf("SELECT count(*) AS n FROM fill f JOIN abx_list a ON a.ndc11 = f.ndc11 WHERE a.generic = '%s'", g))$n, 0)
write_out(trace_sum, "trace_summary.csv")
trace_dx3 <- q("SELECT drug_name, dx3, count(DISTINCT (BENE_ID, fill_dt, ndc11)) AS fills, count(DISTINCT BENE_ID) AS benes FROM trace_dx GROUP BY 1, 2") %>%
  left_join(icd3, by = "dx3") %>% group_by(drug_name) %>% slice_max(fills, n = 25, with_ties = FALSE) %>% ungroup() %>% arrange(drug_name, desc(fills)) %>% mutate(flag_lt11 = fills < MIN_CELL | benes < MIN_CELL)
write_out(trace_dx3, "trace_dx3.csv")
trace_code <- q("SELECT drug_name, code, count(DISTINCT (BENE_ID, fill_dt, ndc11)) AS fills, count(DISTINCT BENE_ID) AS benes FROM trace_dx GROUP BY 1, 2") %>%
  group_by(drug_name) %>% slice_max(fills, n = 25, with_ties = FALSE) %>% ungroup() %>% arrange(drug_name, desc(fills)) %>% mutate(flag_lt11 = fills < MIN_CELL | benes < MIN_CELL)
write_out(trace_code, "trace_dx_code.csv")
# inventory of ALL systemic antibacterial (ATC J01) fills in PDE identified through RxNorm, to re-test amendment A-004's premise
abx_inv <- q("SELECT d.drug_name, count(DISTINCT (f.BENE_ID, f.fill_dt, f.ndc11)) AS fills, count(DISTINCT f.BENE_ID) AS benes
   FROM fill f JOIN ndc_rxcui n ON n.ndc11 = f.ndc11 JOIN rx_atc a ON a.rxcui = n.rxcui AND a.atc_id LIKE 'J01%' JOIN rx_drug d ON d.rxcui = n.rxcui GROUP BY 1 ORDER BY 2 DESC") %>%
  mutate(flag_lt11 = benes < MIN_CELL)
write_out(abx_inv, "pde_antibacterial_inventory.csv")

# ---- 4. candidates and hospitalization counts -----------------------------------------------------------
pick <- function(df, grp, n = 5, per = 2) df %>% arrange(desc(min_arm)) %>% group_by(.data[[grp]]) %>% slice_head(n = per) %>% ungroup() %>% arrange(desc(min_arm)) %>% slice_head(n = n)
# Rule 1 (fixed in advance): smaller arm size. Rule 2 (added AFTER seeing rule-1 results, which were artifacts): indication-specific
# (acute: enrichment >= 3 and >= 50 treated; pairs: arms do not share a product, i.e. co-fill overlap < 20%).
cand <- list(acute_mech = pick(acute_class, "dx3"), pair_mech = pick(pairs, "cond"),
             acute_refined = pick(acute_class %>% filter(enrichment >= 3, n_treated >= 50), "dx3"),
             pair_refined = pick(pairs %>% filter(overlap < 0.2), "cond"))
for (nm in names(cand)) write_out(cand[[nm]], paste0("candidates_", nm, ".csv"))
# Rule 3 (curated, post-hoc, clinical judgement): the rule-based lists above are dominated by artifacts (generic social-problem codes
# with background drugs; insulin products counted under several A10A classes), so these pairs were chosen by hand after reading
# acute_scan.csv / chronic_condition_classes.csv. Pairs across ATC groups (e.g. ACE inhibitor vs thiazide) are allowed here.
pair_stats <- function(cond, a, b) {
  one <- function(x, y) q(sprintf("SELECT count(*) AS n, count(*) FILTER (WHERE EXISTS (SELECT 1 FROM fill_class g WHERE g.BENE_ID = u.BENE_ID AND g.atc_id = %3$s AND g.fill_dt BETWEEN u.idx AND u.idx + 30)) AS n_with
     FROM nu_cond u WHERE u.cond = %1$s AND u.atc_id = %2$s AND NOT EXISTS (SELECT 1 FROM fill_class f WHERE f.BENE_ID = u.BENE_ID AND f.atc_id = %3$s AND f.fill_dt BETWEEN u.idx - 365 AND u.idx - 1)",
     dbQuoteString(con, cond), dbQuoteString(con, x), dbQuoteString(con, y)))
  ra <- one(a, b); rb <- one(b, a)
  tibble(cond = cond, a_cls = a, b_cls = b, n_a = ra$n, n_b = rb$n, n_a_with_b = ra$n_with, n_b_with_a = rb$n_with, min_arm = min(ra$n, rb$n),
         overlap = round(max(ra$n_with / ra$n, rb$n_with / rb$n), 2))
}
manual_acute <- tribble(~dx3, ~atc_id, "J01", "J01CA", "J03", "J01CE", "J02", "J01CE", "J20", "N02BE")
manual_pair <- bind_rows(
  pair_stats("Hypertension", "C09AA", "C03AA"), pair_stats("Hypertension", "C09AA", "C08CA"), pair_stats("Hypertension", "C03AA", "C08CA"),
  pair_stats("Ischemic Heart Disease", "C09AA", "C07AB"), pair_stats("Ischemic Heart Disease", "C08CA", "C07AB")) %>%
  left_join(atc_names %>% rename(a_name = atc_name), by = c("a_cls" = "atc_id")) %>% left_join(atc_names %>% rename(b_name = atc_name), by = c("b_cls" = "atc_id")) %>%
  mutate(flag_lt11 = n_a < MIN_CELL | n_b < MIN_CELL)
cand$acute_curated <- manual_acute %>% left_join(acute_class, by = c("dx3", "atc_id")); cand$pair_curated <- manual_pair
write_out(cand$acute_curated, "candidates_acute_curated.csv"); write_out(cand$pair_curated, "candidates_pair_curated.csv")
cand_acute <- bind_rows(cand$acute_mech %>% mutate(rule = "mechanical"), cand$acute_refined %>% mutate(rule = "refined"), cand$acute_curated %>% mutate(rule = "curated"))
cand_pair <- bind_rows(cand$pair_mech %>% mutate(rule = "mechanical"), cand$pair_refined %>% mutate(rule = "refined"), cand$pair_curated %>% mutate(rule = "curated"))

arm_sql <- function(pop_sql, arm_expr) sprintf("
  WITH pop AS (%s),
  ev AS (SELECT p.*, %s AS arm, (SELECT min(a.adm_dt) FROM adm a WHERE a.BENE_ID = p.BENE_ID AND a.adm_dt BETWEEN p.idx + 1 AND p.idx + 365) AS first_adm FROM pop p)
  SELECT arm, count(*) AS n,
    count(*) FILTER (WHERE idx + 30 <= DATE '%s') AS n_eval_30, count(*) FILTER (WHERE idx + 30 <= DATE '%s' AND first_adm <= idx + 30) AS hosp_30,
    count(*) FILTER (WHERE idx + 365 <= DATE '%s') AS n_eval_365, count(*) FILTER (WHERE idx + 365 <= DATE '%s' AND first_adm IS NOT NULL) AS hosp_365
  FROM ev GROUP BY arm ORDER BY arm", pop_sql, arm_expr, DATA_END, DATA_END, DATA_END, DATA_END)
outcomes <- list()
for (i in seq_len(nrow(cand_acute))) {
  c <- cand_acute[i, ]
  pop <- sprintf("SELECT e.BENE_ID, e.idx, min(f.fill_dt) AS ff FROM acute_ep e LEFT JOIN fill_class f ON f.BENE_ID = e.BENE_ID AND f.atc_id = %s AND f.fill_dt BETWEEN e.idx AND e.idx + 30 WHERE e.dx3 = %s GROUP BY 1, 2",
                 dbQuoteString(con, c$atc_id), dbQuoteString(con, c$dx3))
  r <- q(arm_sql(pop, "CASE WHEN ff IS NULL THEN 'untreated (no class fill 0-30d)' WHEN ff <= idx + 2 THEN 'treated (class fill 0-2d)' ELSE 'late (fill 3-30d, excluded)' END"))
  outcomes[[length(outcomes) + 1]] <- cbind(rule = c$rule, list = "acute", candidate = sprintf("%s %s | %s %s", c$dx3, str_trunc(coalesce(c$dx_description, ""), 40), c$atc_id, str_trunc(c$atc_name, 45)), r)
}
for (i in seq_len(nrow(cand_pair))) {
  c <- cand_pair[i, ]
  pop <- function(x, y) sprintf("SELECT u.BENE_ID, u.idx FROM nu_cond u WHERE u.cond = %s AND u.atc_id = %s AND NOT EXISTS (SELECT 1 FROM fill_class f WHERE f.BENE_ID = u.BENE_ID AND f.atc_id = %s AND f.fill_dt BETWEEN u.idx - 365 AND u.idx - 1)",
                                dbQuoteString(con, c$cond), dbQuoteString(con, x), dbQuoteString(con, y))
  ra <- q(arm_sql(pop(c$a_cls, c$b_cls), dbQuoteString(con, paste0("A: ", c$a_cls)))); rb <- q(arm_sql(pop(c$b_cls, c$a_cls), dbQuoteString(con, paste0("B: ", c$b_cls))))
  outcomes[[length(outcomes) + 1]] <- cbind(rule = c$rule, list = "chronic pair", candidate = sprintf("%s | A %s %s vs B %s %s", str_trunc(c$cond, 35), c$a_cls, str_trunc(c$a_name, 30), c$b_cls, str_trunc(c$b_name, 30)), rbind(ra, rb))
}
out <- bind_rows(outcomes) %>% mutate(flag_lt11 = n < MIN_CELL | hosp_30 < MIN_CELL | hosp_365 < MIN_CELL,
                                       risk_30_pct = round(100 * hosp_30 / n_eval_30, 1), risk_365_pct = round(100 * hosp_365 / n_eval_365, 1))
write_out(out, "candidate_outcomes.csv")
# bronchitis (J20) re-check under ingredient-based identification, to test the premise of amendment A-004
write_out(acute_class %>% filter(dx3 == "J20", n_treated >= 1) %>% arrange(desc(n_treated)), "bronchitis_recheck_classes.csv")
log_step("05_scan", sprintf("candidates (mechanical + refined): %d acute, %d pairs; outcome rows %d", nrow(cand_acute), nrow(cand_pair), nrow(out)), NA, nrow(out))
cat("done
")
