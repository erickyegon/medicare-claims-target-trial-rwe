# Step 02b: exploratory profiling requested at Checkpoint 1 (not used in the cohort).
#  (a) inpatient admission type code: modelled or random?
#  (b) outpatient revenue codes / HCPCS, and whether index setting (carrier vs outpatient) is meaningful.
.root <- (function(d = getwd()) { while (!file.exists(file.path(d, ".project-root"))) d <- dirname(d); d })()
source(file.path(.root, "R", "utils.R"))
con <- connect_db(read_only = TRUE); on.exit(dbDisconnect(con, shutdown = TRUE))
out <- function(x, f) write.csv(x, file.path(PROJ_ROOT, "qc", f), row.names = FALSE)
q <- function(s) dbGetQuery(con, s)

CHAPTER <- "CASE WHEN dx IS NULL THEN 'missing' WHEN left(dx,1) IN ('A','B') THEN 'A-B infectious'
  WHEN left(dx,1)='C' OR (left(dx,1)='D' AND substr(dx,2,2)<'50') THEN 'C-D4 neoplasms' WHEN left(dx,1)='D' THEN 'D5-D8 blood'
  WHEN left(dx,1)='E' THEN 'E endocrine' WHEN left(dx,1)='F' THEN 'F mental' WHEN left(dx,1)='G' THEN 'G nervous' WHEN left(dx,1)='H' THEN 'H eye/ear'
  WHEN left(dx,1)='I' THEN 'I circulatory' WHEN left(dx,1)='J' THEN 'J respiratory' WHEN left(dx,1)='K' THEN 'K digestive' WHEN left(dx,1)='L' THEN 'L skin'
  WHEN left(dx,1)='M' THEN 'M musculoskeletal' WHEN left(dx,1)='N' THEN 'N genitourinary' WHEN left(dx,1)='O' THEN 'O pregnancy'
  WHEN left(dx,1) IN ('S','T') THEN 'S-T injury' WHEN left(dx,1)='R' THEN 'R symptoms' WHEN left(dx,1)='Z' THEN 'Z factors' ELSE 'other' END"
# one row per inpatient claim (file is line-level)
q("CREATE OR REPLACE TEMP TABLE ip AS SELECT CLM_ID, any_value(BENE_ID) BENE_ID, any_value(CLM_IP_ADMSN_TYPE_CD) adm_type,
   any_value(CLM_SRC_IP_ADMSN_CD) src, any_value(PRNCPAL_DGNS_CD) dx, any_value(year(CLM_ADMSN_DT)) yr,
   any_value(ADMTG_DGNS_CD) admit_dx FROM inpatient GROUP BY CLM_ID")
ip <- list(
  overall = q("SELECT adm_type, count(*) n_claims, round(100.0*count(*)/sum(count(*)) OVER (),1) pct FROM ip GROUP BY 1 ORDER BY 1"),
  by_chapter = q(sprintf("SELECT chapter, adm_type, count(*) n FROM (SELECT adm_type, %s AS chapter FROM ip) GROUP BY ALL ORDER BY 1,2", CHAPTER)),
  by_year = q("SELECT yr, adm_type, count(*) n FROM ip GROUP BY ALL ORDER BY 1,2"),
  x_source = q("SELECT adm_type, src, count(*) n FROM ip GROUP BY ALL ORDER BY 1,2"))
tab <- xtabs(n ~ chapter + adm_type, ip$by_chapter); tab_main <- tab[rowSums(tab) >= 50, , drop = FALSE]
ip$chisq_chapter <- data.frame(test = "adm_type x principal dx chapter (chapters with >=50 claims)", df = chisq.test(tab_main)$parameter,
  chisq = unname(chisq.test(tab_main)$statistic), p = chisq.test(tab_main)$p.value, cramers_v = sqrt(unname(chisq.test(tab_main)$statistic) / (sum(tab_main) * (min(dim(tab_main)) - 1))))
tab2 <- xtabs(n ~ src + adm_type, ip$x_source); c2 <- chisq.test(tab2)
ip$chisq_source <- data.frame(test = "adm_type x admission source", df = c2$parameter, chisq = unname(c2$statistic), p = c2$p.value,
  cramers_v = sqrt(unname(c2$statistic) / (sum(tab2) * (min(dim(tab2)) - 1))))
ip$within_bene <- q("SELECT count(*) n_benes_2plus_adm, count(*) FILTER (WHERE k > 1) n_with_mixed_types FROM (SELECT BENE_ID, count(DISTINCT adm_type) k FROM ip GROUP BY 1 HAVING count(*) > 1)")
for (n in names(ip)) out(ip[[n]], paste0("profile_ip_", n, ".csv"))

# ---- outpatient ----
op <- list(
  rev_hcpcs = q("SELECT REV_CNTR, HCPCS_CD, count(*) n_rows, count(DISTINCT CLM_ID) n_claims FROM outpatient GROUP BY ALL ORDER BY 3 DESC, 1, 2 LIMIT 40"),
  rev_vs_claim_class = q("SELECT REV_CNTR, CLM_SRVC_CLSFCTN_TYPE_CD, count(*) n FROM outpatient GROUP BY ALL ORDER BY 1,2"),
  rev_per_claim = q("SELECT n_lines, n_0001, count(*) n_claims FROM (SELECT CLM_ID, count(*) n_lines, count(*) FILTER (WHERE REV_CNTR='0001') n_0001 FROM outpatient GROUP BY 1) GROUP BY ALL ORDER BY 1, 2 LIMIT 15"),
  telemed_hcpcs = q("SELECT HCPCS_CD, count(*) n FROM outpatient WHERE REV_CNTR IN ('0780','0789') GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 15"),
  # which claims carry bronchitis, by file (this is what 'index setting' would distinguish)
  bronch_by_file = q("SELECT src, count(DISTINCT CLM_ID) claims, count(DISTINCT BENE_ID) benes FROM (
      SELECT 'carrier' src, CLM_ID, BENE_ID FROM carrier WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%'
      UNION ALL SELECT 'outpatient', CLM_ID, BENE_ID FROM outpatient WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%') GROUP BY 1 ORDER BY 1"),
  hcpcs_top_outpatient = q("SELECT HCPCS_CD, count(*) n FROM outpatient GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 12"),
  hcpcs_top_carrier = q("SELECT HCPCS_CD, count(*) n FROM carrier GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 12"),
  carrier_pos = q("SELECT LINE_PLACE_OF_SRVC_CD pos, LINE_CMS_TYPE_SRVC_CD type_srvc, count(*) n FROM carrier GROUP BY ALL ORDER BY 3 DESC, 1, 2 LIMIT 12"))
# do bronchitis diagnoses appear in both files for the same person/day? (setting overlap)
op$bronch_overlap <- q("WITH b AS (SELECT DISTINCT 'carrier' src, BENE_ID, CLM_FROM_DT d FROM carrier WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%'
   UNION SELECT 'outpatient', BENE_ID, CLM_FROM_DT FROM outpatient WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%')
  SELECT n_src, count(*) n_bene_days FROM (SELECT BENE_ID, d, count(DISTINCT src) n_src FROM b GROUP BY 1,2) GROUP BY 1 ORDER BY 1")
# does setting relate to patient characteristics? first bronchitis claim per bene: setting vs age, sex, any prior-year hospitalization
op$setting_vs_age <- q("WITH f AS (SELECT BENE_ID, src, d, row_number() OVER (PARTITION BY BENE_ID ORDER BY d, src) rn FROM (
    SELECT 'carrier' src, BENE_ID, CLM_FROM_DT d FROM carrier WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%'
    UNION ALL SELECT 'outpatient', BENE_ID, CLM_FROM_DT FROM outpatient WHERE PRNCPAL_DGNS_CD LIKE 'J20%' OR ICD_DGNS_CD1 LIKE 'J20%'))
  SELECT src, count(*) n, round(avg(date_diff('year', b.BENE_BIRTH_DT, f.d)),1) mean_age,
    round(100*avg((b.SEX_IDENT_CD='2')::INT),1) pct_female,
    round(100*avg(EXISTS (SELECT 1 FROM inpatient i WHERE i.BENE_ID=f.BENE_ID AND i.CLM_ADMSN_DT BETWEEN f.d - 365 AND f.d - 1)::INT),1) pct_prior_year_admission
  FROM f JOIN (SELECT BENE_ID, min(BENE_BIRTH_DT) BENE_BIRTH_DT, any_value(SEX_IDENT_CD) SEX_IDENT_CD FROM bene GROUP BY 1) b USING (BENE_ID) WHERE rn=1 GROUP BY 1 ORDER BY 1")
for (n in names(op)) out(op[[n]], paste0("profile_op_", n, ".csv"))
cat("IP\n"); for (n in names(ip)) { cat("\n--", n, "\n"); print(ip[[n]], row.names = FALSE) }
cat("\nOP\n"); for (n in names(op)) { cat("\n--", n, "\n"); print(op[[n]], row.names = FALSE) }
