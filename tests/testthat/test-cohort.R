# Hand-built beneficiaries, one per criterion, including boundary cases. Index date is 2018-06-15 unless stated.
# NDCs: A = ACE inhibitor, T = thiazide, AT = fixed-dose ACEI+thiazide, C = CCB, R = ARB, UNK = no RxNorm record.
IDX <- d("2018-06-15")
full <- months_between("2016-01-01", "2019-12-01")

make_cohort_db <- function() {
  con <- new_con()
  ids <- sprintf("P%02d", 1:20)
  b <- lapply(ids, function(id) {
    birth <- if (id == "P03") "1953-10-01" else "1940-01-01"
    ab <- full; dm <- full
    if (id == "P04") dm <- setdiff(dm, as.Date("2017-12-01"))                       # Part D gap inside the baseline year
    if (id == "P15") { ab <- months_between("2017-06-01", "2019-12-01"); dm <- ab }   # enrollment starts exactly in the month of day -365
    if (id == "P16") { ab <- months_between("2017-07-01", "2019-12-01"); dm <- ab }   # one month too short
    mk_bene(id, birth, ab, dm)
  })
  dbWriteTable(con, "bene", bind_rows(b)); build_enrollment(con)
  dbExecute(con, "CREATE TABLE demo AS SELECT BENE_ID, min(BENE_BIRTH_DT) AS birth, any_value(SEX_IDENT_CD) AS sex FROM bene GROUP BY 1")

  rx <- function(id, dt, ndc, ds = 30) data.frame(BENE_ID = id, fill_dt = d(dt), ndc11 = ndc, days_supply = ds)
  fills <- bind_rows(
    rx("P01", IDX, "A"), rx("P02", "2018-03-01", "C"), rx("P02", IDX, "A"),
    rx("P03", "2018-06-15", "A", 90), rx("P03", "2019-09-01", "A"),
    rx("P04", IDX, "A"), rx("P05", IDX, "A"), rx("P06", IDX, "A"),
    rx("P07", IDX, "A"), rx("P07", IDX, "T"), rx("P08", IDX, "AT"),
    rx("P09", IDX, "A"), rx("P10", IDX, "A"), rx("P11", IDX, "A"), rx("P12", IDX, "T"),
    rx("P13", "2018-02-01", "UNK"), rx("P13", IDX, "A"),
    rx("P14", "2016-02-15", "A"),
    rx("P15", IDX, "A"), rx("P16", IDX, "A"),
    rx("P17", "2017-06-14", "R"), rx("P17", IDX, "A"),        # ARB 366 days before index: outside the washout window
    rx("P18", "2017-06-15", "R"), rx("P18", IDX, "A"),        # ARB exactly 365 days before: inside the window
    rx("P19", IDX, "A"), rx("P19", IDX, "C"),                  # ACE inhibitor + CCB started the same day (separate products)
    rx("P20", IDX, "AC"))                                      # fixed-dose ACEI + CCB product
  dbWriteTable(con, "rx_fill", fills)
  dx <- function(id, dt) data.frame(BENE_ID = id, CLM_ID = paste0(id, dt), dt = d(dt), src = "carrier", code = "I10", dx3 = "I10")
  with_htn <- setdiff(ids, c("P05", "P06", "P14"))
  dxs <- bind_rows(lapply(with_htn, function(id) dx(id, "2018-01-10")), dx("P03", "2019-06-01"), dx("P06", "2018-06-15"))   # P06: only on the index date (allowed by A-009)
  dbWriteTable(con, "dx_long", dxs)
  dbWriteTable(con, "hospice_clm", data.frame(BENE_ID = "P09", from_dt = d("2017-10-01"), thru_dt = d("2017-12-31")))
  dbWriteTable(con, "ip_stay", data.frame(BENE_ID = c("P10", "P11"), adm_dt = d(c("2018-06-10", "2018-06-01")), thru_dt = d(c("2018-06-20", "2018-06-14"))))
  ndc <- data.frame(ndc11 = c("A", "T", "AT", "AT", "AC", "AC", "C", "R"), ahtn_class = c("ACEI", "THIAZIDE", "ACEI", "THIAZIDE", "ACEI", "CCB", "CCB", "ARB"))
  register_cohort_inputs(con, ndc, data.frame(ndc11 = c("A", "T", "AT", "AC", "C", "R")), data.frame(code = "I10"))
  con
}

test_that("attrition counts follow the protocol order, one reason per excluded person", {
  con <- make_cohort_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  r <- build_cohort(con, log = FALSE); a <- r$attrition
  # P14 never a candidate; new user removes P02+P18; age removes only P03's first candidate; enrollment P04+P16; diagnosis P05 (P06 passes: index-date diagnosis is
  # allowed, A-009); both study drugs P07+P08; other class on the index date P19+P20 (A-010); hospice P09; inpatient overlap P10
  expect_equal(a$n_persons, c(20, 19, 17, 17, 15, 14, 12, 10, 9, 8, 8))
  expect_equal(a$n_episodes[2:10], c(20, 18, 17, 15, 14, 12, 10, 9, 8))
  expect_equal(a$step, 0:10)
  expect_equal(sort(dbGetQuery(con, "SELECT BENE_ID FROM htn_cohort")$BENE_ID), c("P01", "P03", "P06", "P11", "P12", "P13", "P15", "P17"))
})

test_that("first qualifying episode is used and the arm follows the study drug filled on the index date", {
  con <- make_cohort_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  build_cohort(con, log = FALSE)
  h <- dbGetQuery(con, "SELECT * FROM htn_cohort ORDER BY BENE_ID")
  expect_equal(as.character(h$idx[h$BENE_ID == "P03"]), "2019-09-01")   # age 64 on the first candidate, 65 on the second
  expect_equal(h$arm[h$BENE_ID == "P12"], "THIAZIDE"); expect_equal(h$arm[h$BENE_ID == "P01"], "ACEI")
  expect_equal(sum(h$arm == "ACEI"), 7); expect_equal(sum(h$arm == "THIAZIDE"), 1)
  expect_false(any(h$costart))
})

test_that("boundaries: washout window, enrollment start, same-day products, inpatient end date, diagnosis on the index date", {
  con <- make_cohort_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  build_cohort(con, log = FALSE)
  f <- dbGetQuery(con, "SELECT * FROM cand_flags WHERE idx = DATE '2018-06-15'")
  g <- function(id, col) f[[col]][f$BENE_ID == id]
  expect_true("P17" %in% f$BENE_ID)                                  # ARB 366 days earlier is outside [-365, -1], so P17 is a new user
  expect_false("P18" %in% f$BENE_ID)                                 # ARB exactly 365 days earlier removes P18 at the new-user step
  expect_true(g("P15", "f_enroll")); expect_false(g("P16", "f_enroll")); expect_false(g("P04", "f_enroll"))
  expect_false(g("P07", "f_notboth")); expect_false(g("P08", "f_notboth"))   # separate products and the combination product both count as both
  expect_false(g("P09", "f_nohospice"))
  expect_false(g("P10", "f_noinpt")); expect_true(g("P11", "f_noinpt"))      # discharge the day before index does not overlap
  expect_true(g("P06", "f_htn")); expect_false(g("P06", "f_htn_strict"))     # diagnosis only on the index date: eligible (A-009), not in the strict window
  expect_false(g("P05", "f_htn")); expect_true(g("P01", "f_htn_strict"))
  expect_false(g("P19", "f_nocostart")); expect_false(g("P20", "f_nocostart")); expect_true(g("P01", "f_nocostart"))   # separate product and combination product both count
  expect_true(g("P13", "info_no_rxnorm_baseline_fill")); expect_false(g("P01", "info_no_rxnorm_baseline_fill"))
})

test_that("sensitivity cohorts re-select the first qualifying episode under their own rule", {
  con <- make_cohort_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  r <- build_cohort(con, log = FALSE); s <- r$sensitivity_cohorts
  expect_equal(s$n_persons, c(8, 10, 7, 7)); expect_equal(s$ACEI, c(7, 9, 6, 6)); expect_equal(s$THIAZIDE, c(1, 1, 1, 1))
  co <- dbGetQuery(con, "SELECT BENE_ID, costart FROM htn_cohort_costart WHERE costart ORDER BY BENE_ID")
  expect_equal(co$BENE_ID, c("P19", "P20"))                                  # kept with an indicator
  expect_false("P06" %in% dbGetQuery(con, "SELECT BENE_ID FROM htn_cohort_strictdx")$BENE_ID)
  expect_false("P13" %in% dbGetQuery(con, "SELECT BENE_ID FROM htn_cohort_nounid")$BENE_ID)
  expect_equal(r$informational$n_persons, c(1, 1, 2))                         # P13 baseline fill with no RxNorm record; P06 index-date diagnosis only; P19+P20 co-starters
})
