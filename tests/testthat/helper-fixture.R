# Small synthetic fixture in the raw CMS-file schema (about 700 people), used by the end-to-end test and by CI.
# Pure simulation (seeded): no real or CMS data. Fake NDCs: 10000000001 ACE inhibitor, 10000000002 thiazide, 10000000003 calcium-channel blocker.
suppressPackageStartupMessages(library(tidyr))

make_fixture_raw <- function(con, n = 700, seed = 42) {
  set.seed(seed); ids <- sprintf("S%04d", seq_len(n)); rd <- function(a, b, k) as.Date(a) + sample.int(as.integer(as.Date(b) - as.Date(a)), k, TRUE) - 1L
  birth <- as.Date("1925-01-01") + sample.int(as.integer(as.Date("1958-12-31") - as.Date("1925-01-01")), n, TRUE)
  diabetes <- rbinom(n, 1, 0.3); ihd <- rbinom(n, 1, 0.4)
  # --- enrollment: Part A+B all months 2015-2022 for most; Part D from a start month until a random end (or never)
  ab_end <- ifelse(runif(n) < 0.9, as.Date("2022-12-01"), as.Date("2019-01-01") + 30 * sample.int(40, n, TRUE))
  has_d <- runif(n) < 0.85; d_start <- as.Date("2015-01-01") + 31 * sample.int(8, n, TRUE); d_end <- as.Date(ifelse(runif(n) < 0.7, as.Date("2022-12-01"), as.Date("2019-06-01") + 30 * sample.int(40, n, TRUE)))
  fl <- function(x) as.Date(format(x, "%Y-%m-01"))
  bene <- do.call(rbind, lapply(seq_len(n), function(i) {
    yrs <- 2015:2022; abm <- seq(as.Date("2015-01-01"), fl(as.Date(ab_end[i])), by = "month"); dm <- if (has_d[i]) seq(fl(d_start[i]), fl(d_end[i]), by = "month") else as.Date(character())
    do.call(rbind, lapply(yrs, function(y) {
      ms <- as.Date(sprintf("%d-%02d-01", y, 1:12)); a <- ms %in% abm; d <- ms %in% dm
      if (!any(a | d)) return(NULL)
      r <- data.frame(BENE_ID = ids[i], BENE_ENROLLMT_REF_YR = as.character(y), BENE_BIRTH_DT = birth[i], SEX_IDENT_CD = as.character(1 + (i %% 2)), STATE_CODE = c("05", "33", "14", "10")[1 + i %% 4], BENE_RACE_CD = c("1", "1", "2", "5")[1 + i %% 4], stringsAsFactors = FALSE)
      for (m in 1:12) { r[[sprintf("MDCR_ENTLMT_BUYIN_IND_%02d", m)]] <- ifelse(a[m], "3", "0"); r[[sprintf("PTD_CNTRCT_ID_%02d", m)]] <- ifelse(d[m], "Z0001", NA_character_) }
      r }))
  }))
  # --- exposure: most people start an ACE inhibitor or thiazide; some have an earlier other-class fill (not new users); some co-start a CCB
  start <- rd("2016-06-01", "2021-12-31", n); starts <- runif(n) < 0.85; age_at <- as.numeric(start - birth) / 365.25
  acei <- runif(n) < plogis(-0.4 + 0.03 * (age_at - 75) + 0.4 * diabetes); ndc <- ifelse(acei, "10000000001", "10000000002")
  fills <- bind_rows(
    data.frame(BENE_ID = ids[starts], SRVC_DT = start[starts], PROD_SRVC_ID = ndc[starts], DAYS_SUPLY_NUM = 90),
    data.frame(BENE_ID = ids[starts], SRVC_DT = start[starts] + 365, PROD_SRVC_ID = ndc[starts], DAYS_SUPLY_NUM = 90),
    data.frame(BENE_ID = ids[starts & runif(n) < 0.15], SRVC_DT = NA, PROD_SRVC_ID = "10000000003", DAYS_SUPLY_NUM = 30) %>% mutate(SRVC_DT = start[match(BENE_ID, ids)] - sample(30:300, n(), TRUE)),
    data.frame(BENE_ID = ids[starts & runif(n) < 0.10], SRVC_DT = NA, PROD_SRVC_ID = "10000000003", DAYS_SUPLY_NUM = 30) %>% mutate(SRVC_DT = start[match(BENE_ID, ids)]),
    local({ sel <- starts & runif(n) < 0.05; data.frame(BENE_ID = ids[sel], SRVC_DT = start[sel] + sample(5:60, sum(sel), TRUE), PROD_SRVC_ID = ifelse(acei[sel], "10000000002", "10000000001"), DAYS_SUPLY_NUM = 90) })) %>%   # add-on / switch fills
    filter(SRVC_DT <= as.Date("2023-03-02"))
  # --- diagnoses: hypertension before (or on) the start for most; diabetes and ischemic heart disease
  dxrow <- function(id, dt, code) data.frame(BENE_ID = id, CLM_FROM_DT = dt, code = code, stringsAsFactors = FALSE)
  htn <- starts & runif(n) < 0.88
  dxl <- bind_rows(dxrow(ids[htn], start[htn] - sample(0:300, sum(htn), TRUE), "I10"), dxrow(ids[diabetes == 1], rd("2015-06-01", "2021-12-31", sum(diabetes)), "E119"),
                   dxrow(ids[ihd == 1], rd("2015-06-01", "2021-12-31", sum(ihd)), "I251"), dxrow(ids, rd("2015-06-01", "2022-12-31", n), "M545")) %>% mutate(CLM_ID = paste0("C", seq_len(n())))
  wide <- function(d, k) { m <- matrix(NA_character_, nrow(d), k, dimnames = list(NULL, paste0("ICD_DGNS_CD", seq_len(k)))); m[, 1] <- d$code; cbind(d[, c("BENE_ID", "CLM_ID", "CLM_FROM_DT")], PRNCPAL_DGNS_CD = d$code, as.data.frame(m, stringsAsFactors = FALSE)) }
  half <- seq_len(nrow(dxl)) %% 2 == 0
  # --- hospitalizations: hazard rises with age and slightly with the ACE-inhibitor arm; a few earlier admissions
  t_h <- rexp(n, (0.0003 + 0.00002 * pmax(age_at - 65, 0)) * ifelse(acei, 1.2, 1)); adm <- start + ceiling(t_h)
  pre <- runif(n) < 0.15; adm_pre <- start - sample(10:300, n, TRUE)
  ip <- bind_rows(data.frame(BENE_ID = ids[starts & t_h < 800], adm = adm[starts & t_h < 800]), data.frame(BENE_ID = ids[starts & pre], adm = adm_pre[starts & pre])) %>% filter(adm <= as.Date("2023-03-02")) %>%
    mutate(CLM_ID = paste0("I", seq_len(n())), CLM_FROM_DT = adm, CLM_ADMSN_DT = adm, CLM_THRU_DT = adm + 3, code = "R079")
  ipw <- wide(ip %>% select(BENE_ID, CLM_ID, CLM_FROM_DT, code), 25); ipw$CLM_ADMSN_DT <- ip$CLM_ADMSN_DT; ipw$CLM_THRU_DT <- ip$CLM_THRU_DT
  hos <- data.frame(BENE_ID = ids[runif(n) < 0.02], stringsAsFactors = FALSE); hos$CLM_FROM_DT <- rd("2016-01-01", "2022-06-30", nrow(hos)); hos$CLM_THRU_DT <- hos$CLM_FROM_DT + 60
  for (t in c("bene", "carrier", "outpatient", "inpatient", "pde", "hospice")) if (dbExistsTable(con, t)) dbRemoveTable(con, t)
  dbWriteTable(con, "bene", bene); dbWriteTable(con, "carrier", wide(dxl[half, ], 12)); dbWriteTable(con, "outpatient", wide(dxl[!half, ], 25)); dbWriteTable(con, "inpatient", ipw)
  dbWriteTable(con, "pde", fills); dbWriteTable(con, "hospice", hos)
  invisible(list(n = n))
}

fixture_lookups <- function(con) {
  ndc_ahtn <- data.frame(ndc11 = c("10000000001", "10000000002", "10000000003"), ahtn_class = c("ACEI", "THIAZIDE", "CCB"))
  register_cohort_inputs(con, ndc_ahtn, data.frame(ndc11 = ndc_ahtn$ndc11), data.frame(code = "I10"))
  register_baseline_inputs(con, data.frame(grp = c("diabetes", "ischemic_heart_disease"), code = c("E119", "I251")),
                           data.frame(ndc11 = ndc_ahtn$ndc11, drug_name = c("acei", "thiazide", "ccb")), data.frame(ndc11 = ndc_ahtn$ndc11, atc_id = c("C09AA", "C03AA", "C08CA")))
  duckdb::duckdb_register(con, "icd_fx", data.frame(code = "S72009"))
}
