source(file.path(.root, "R", "08_baseline.R"))

# Two hand-built people. Index 2018-06-15, so the covariate window is 2017-06-15 (day -365) to 2018-06-14 (day -1).
make_base_db <- function() {
  con <- new_con(); idx <- d("2018-06-15")
  dbWriteTable(con, "htn_cohort", data.frame(BENE_ID = c("B1", "B2"), idx = idx, arm = c("ACEI", "THIAZIDE"), costart = FALSE, no_rxnorm_baseline = FALSE))
  dbWriteTable(con, "demo", data.frame(BENE_ID = c("B1", "B2"), birth = d(c("1950-06-15", "1950-06-16")), sex = c("2", "1")))
  dbWriteTable(con, "bene_year", data.frame(BENE_ID = c("B1", "B1", "B2"), yr = c(2017L, 2018L, 2017L), state = c("05", "33", "14"), race = c("1", "2", "5")))
  cl <- function(id, dt, src, code) data.frame(BENE_ID = id, CLM_ID = paste(id, dt, src, code), dt = d(dt), src = src, code = code, dx3 = substr(code, 1, 3))
  dbWriteTable(con, "dx_long", bind_rows(
    cl("B1", "2017-06-15", "carrier", "E119"),      # day -365: counts (diabetes) and is a visit day
    cl("B1", "2017-06-14", "carrier", "I251"),      # day -366: outside the window
    cl("B1", "2018-06-14", "outpatient", "J449"),   # day -1: counts (COPD) and is a visit day
    cl("B1", "2018-06-15", "carrier", "N189"),      # index date: not a baseline covariate (A-009)
    cl("B1", "2018-01-10", "inpatient", "E119"),    # inpatient claims count for conditions but not as visit days
    cl("B1", "2018-03-01", "carrier", "M545"), cl("B1", "2018-03-01", "outpatient", "M545")))   # same date in both files: one visit day
  dbWriteTable(con, "ip_stay", data.frame(BENE_ID = "B1", adm_dt = d(c("2018-01-10", "2018-06-15", "2017-06-14")), thru_dt = d(c("2018-01-12", "2018-06-17", "2017-06-16"))))
  rx <- function(id, dt, ndc) data.frame(BENE_ID = id, fill_dt = d(dt), ndc11 = ndc, days_supply = 30)
  dbWriteTable(con, "rx_fill", bind_rows(rx("B1", "2017-07-01", "N1"), rx("B1", "2017-08-01", "N1"), rx("B1", "2018-01-01", "N2"),
                                         rx("B1", "2018-06-15", "N3"), rx("B1", "2017-06-14", "N4")))
  register_baseline_inputs(con,
    ccw_codes = data.frame(grp = c("diabetes", "ischemic_heart_disease", "copd", "chronic_kidney_disease"), code = c("E119", "I251", "J449", "N189")),
    ndc_drug = data.frame(ndc11 = c("N1", "N2", "N3", "N4"), drug_name = c("drugA", "drugB", "drugC", "drugD")),
    ndc_atc = data.frame(ndc11 = c("N1", "N2", "N2", "N3", "N4"), atc_id = c("A1", "B1", "B2", "C1", "D1")))
  con
}

test_that("covariates use days -365 to -1 only", {
  con <- make_base_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  b <- build_baseline(con); g <- function(id, col) b[[col]][b$BENE_ID == id]
  expect_equal(g("B1", "diabetes"), 1L); expect_equal(g("B1", "copd"), 1L)
  expect_equal(g("B1", "ischemic_heart_disease"), 0L)      # claim on day -366
  expect_equal(g("B1", "chronic_kidney_disease"), 0L)      # claim on the index date
  expect_equal(g("B1", "asthma"), 0L); expect_equal(g("B1", "cancer"), 0L)
  expect_equal(g("B1", "visit_days"), 3)                   # 2017-06-15, 2018-03-01 (counted once), 2018-06-14
  expect_equal(g("B1", "n_admissions"), 1); expect_equal(g("B1", "prior_hosp"), 1L)   # admissions on the index date and on day -365-1 do not count
  expect_equal(g("B1", "n_drugs"), 2); expect_equal(g("B1", "n_classes"), 3)          # drugA twice counts once; drugB has two ATC classes; day 0 and day -366 fills excluded
  expect_equal(g("B2", "visit_days"), 0); expect_equal(g("B2", "n_drugs"), 0); expect_equal(g("B2", "prior_hosp"), 0L)
})

test_that("age at index, demographic labels and region", {
  con <- make_base_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  b <- build_baseline(con); g <- function(id, col) b[[col]][b$BENE_ID == id]
  expect_equal(g("B1", "age"), 68); expect_equal(g("B2", "age"), 67)           # birthday on the index date counts; the day before does not
  expect_equal(as.character(g("B1", "sex")), "female"); expect_equal(as.character(g("B2", "sex")), "male")
  expect_equal(as.character(g("B1", "region")), "Northeast"); expect_equal(as.character(g("B1", "race")), "Black")   # state and race from the index-year row (2018)
  expect_equal(as.character(g("B2", "region")), "Midwest"); expect_equal(as.character(g("B2", "race")), "Hispanic")   # no 2018 row: earliest row is used
  expect_equal(ssa_region(c("05", "33", "14", "10", "40", NA)), c("West", "Northeast", "Midwest", "South", "other", "unknown"))
  # codes 48-53 follow the official ResDAC table (48 = Virgin Islands, 49 Virginia, 50 Washington, 51 West Virginia, 52 Wisconsin, 53 Wyoming)
  expect_equal(ssa_region(c("48", "49", "50", "51", "52", "53", "67", "64")), c("other", "South", "West", "South", "Midwest", "West", "South", "other"))
  expect_equal(race_label(c("1", "6", "0", NA, "9")), c("White", "Native American", "unknown", "unknown", "unknown"))
  expect_equal(g("B1", "arm_acei"), 1L); expect_equal(g("B2", "arm_acei"), 0L)
})
