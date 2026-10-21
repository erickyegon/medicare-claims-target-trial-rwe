# --- supply timeline (pure function) -------------------------------------------------------------------------
fl <- function(days, supply) data.frame(fill_dt = d("2018-01-01") + days, days_supply = supply)

test_that("discontinuation = end of supply + 30-day grace when there is no refill", {
  t <- supply_timeline(fl(0, 30))
  expect_equal(t$last_supply_end, d("2018-01-30")); expect_equal(t$discontinuation_dt, d("2018-03-01"))
})

test_that("on-time refills extend coverage; early refills carry forward", {
  expect_equal(supply_timeline(fl(c(0, 30), c(30, 30)))$last_supply_end, d("2018-03-01"))          # second supply starts the day after the first ends
  expect_equal(supply_timeline(fl(c(0, 10), c(30, 30)))$last_supply_end, d("2018-03-01"))          # early refill: carried forward, not wasted
  expect_equal(supply_timeline(fl(c(0, 10), c(30, 30)))$discontinuation_dt, d("2018-03-31"))
})

test_that("a refill within the grace period continues treatment; a later one does not", {
  within <- supply_timeline(fl(c(0, 59), c(30, 30)))        # supply ends day 29; day 59 = end + 30: still inside the grace period
  expect_equal(within$last_supply_end, d("2018-03-30"))
  beyond <- supply_timeline(fl(c(0, 60, 120), c(30, 30, 30)))   # day 60 = end + 31: discontinued at day 59; later fills ignored
  expect_equal(beyond$discontinuation_dt, d("2018-03-01")); expect_equal(beyond$last_supply_end, d("2018-01-30"))
})

test_that("other study drug is an add-on while the index class has supply and a switch afterwards", {
  expect_equal(supply_timeline(fl(0, 30), other_dt = d("2018-01-11"))$other_type, "add-on")
  expect_equal(supply_timeline(fl(0, 30), other_dt = d("2018-01-30"))$other_type, "add-on")        # last covered day
  expect_equal(supply_timeline(fl(0, 30), other_dt = d("2018-01-31"))$other_type, "switch")        # supply gone, still inside the grace period
  expect_equal(supply_timeline(fl(0, 30), other_dt = d("2018-05-01"))$other_type, "switch")        # after discontinuation
  expect_true(is.na(supply_timeline(fl(0, 30))$other_type))
})

# --- follow-up, outcomes and censoring on hand-built persons ---------------------------------------------------
# Common shape: persons F1..F9, index 2018-01-01 (F4: 2019-06-01), ACE-inhibitor arm, 30-day index fill.
add_fu_inputs <- function(con, ids, idx, ab_end, abd_end, arm = "ACEI") {
  dbWriteTable(con, "htn_cohort", data.frame(BENE_ID = ids, idx = idx, arm = arm, costart = FALSE, no_rxnorm_baseline = FALSE))
  dbWriteTable(con, "enroll_ab_span", data.frame(BENE_ID = ids, span_start = d("2016-01-01"), span_end = ab_end))
  dbWriteTable(con, "enroll_span", data.frame(BENE_ID = ids, span_start = d("2016-01-01"), span_end = abd_end))
}
make_fu_db <- function() {
  con <- new_con(); I <- d("2018-01-01")
  ids <- paste0("F", 1:9); idx <- rep(I, 9); idx[4] <- d("2019-06-01")
  ab_end <- rep(d("2019-12-31"), 9); ab_end[3] <- d("2018-06-30"); abd_end <- ab_end; abd_end[9] <- d("2018-05-31")   # F3: A/B lost; F9: only Part D lost
  add_fu_inputs(con, ids, idx, ab_end, abd_end)
  dbWriteTable(con, "ip_stay", data.frame(BENE_ID = c("F1", "F2", "F2", "F3", "F6"), adm_dt = d(c("2018-02-01", "2018-01-01", "2019-01-02", "2018-08-01", "2018-03-01")), thru_dt = d(c("2018-02-03", "2018-01-02", "2019-01-04", "2018-08-02", "2018-03-02"))))
  dbWriteTable(con, "dx_long", data.frame(BENE_ID = "F5", CLM_ID = "c1", dt = d("2018-03-01"), src = "carrier", code = "S72009", dx3 = "S72"))
  duckdb::duckdb_register(con, "icd_fx", data.frame(code = "S72009"))
  ahtn <- function(id, dt, ds, cls) data.frame(BENE_ID = id, fill_dt = d(dt), days_supply = ds, ahtn_class = cls)
  fills <- bind_rows(
    lapply(setdiff(ids, "F9"), function(i) ahtn(i, if (i == "F4") "2019-06-01" else "2018-01-01", 30, "ACEI")) %>% bind_rows(),
    ahtn("F6", "2018-01-20", 30, "THIAZIDE"),                                           # add-on while covered
    ahtn("F7", "2018-03-01", 30, "THIAZIDE"),                                           # switch after the supply ran out
    ahtn("F8", "2018-01-29", 30, "ACEI"), ahtn("F8", "2018-02-26", 30, "ACEI"), ahtn("F8", "2018-03-26", 30, "ACEI"), ahtn("F8", "2018-04-23", 30, "ACEI"),
    ahtn("F8", "2018-05-21", 30, "ACEI"), ahtn("F8", "2018-06-18", 30, "ACEI"), ahtn("F8", "2018-07-16", 30, "ACEI"), ahtn("F8", "2018-08-13", 30, "ACEI"),
    ahtn("F8", "2018-09-10", 30, "ACEI"), ahtn("F8", "2018-10-08", 30, "ACEI"), ahtn("F8", "2018-11-05", 30, "ACEI"), ahtn("F8", "2018-12-03", 30, "ACEI"),
    ahtn("F8", "2018-12-31", 30, "ACEI"),                                               # F8 refills every 28 days with a 30-day supply and never discontinues
    ahtn("F9", "2018-01-01", 90, "ACEI"), ahtn("F9", "2018-04-01", 90, "ACEI"))        # F9 supply runs to 2018-06-29; Part D is lost on 2018-05-31 first
  dbWriteTable(con, "ahtn_fill", fills)
  con
}

test_that("ITT follow-up ends at day 365, end of data, or loss of A/B/D entitlement; window and negative control", {
  con <- make_fu_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  fu <- build_followup(con, data_end = d("2019-12-31")); g <- function(id, col) fu[[col]][fu$BENE_ID == id]
  expect_equal(g("F1", "itt_end"), d("2019-01-01")); expect_equal(g("F1", "itt_end_reason"), "day 365")
  expect_equal(g("F1", "hosp_dt"), d("2018-02-01"))
  expect_true(is.na(g("F2", "hosp_dt")))                                  # admission on the index date (day 0) and on day 366 are both outside days 1-365
  expect_equal(g("F3", "itt_end"), d("2018-06-30")); expect_equal(g("F3", "itt_end_reason"), "loss of Part A/B/D")
  expect_true(is.na(g("F3", "hosp_dt")))                                  # admission after entitlement ended is not observable
  expect_equal(g("F4", "itt_end"), d("2019-12-31")); expect_equal(g("F4", "itt_end_reason"), "end of data")
  expect_equal(g("F9", "itt_end"), d("2018-05-31")); expect_equal(g("F9", "itt_end_reason"), "loss of Part A/B/D")   # loss of Part D alone now ends ITT follow-up (A-008)
  expect_equal(g("F9", "itt_end_ab"), d("2019-01-01"))                    # sensitivity rule: ignoring Part D, follow-up would run to day 365
  expect_equal(g("F5", "fx_dt"), d("2018-03-01")); expect_true(is.na(g("F1", "fx_dt")))
})

test_that("end of data is 2023-03-31, not the last claim date; people still enrolled are followed to day 365", {
  con <- new_con(); on.exit(dbDisconnect(con, shutdown = TRUE))
  ids <- c("G1", "G2", "G3"); idx <- d(c("2022-03-15", "2022-04-15", "2022-03-15")); end <- d(c("2023-12-31", "2023-12-31", "2022-09-30"))
  add_fu_inputs(con, ids, idx, ab_end = end, abd_end = end)
  dbWriteTable(con, "ip_stay", data.frame(BENE_ID = character(), adm_dt = as.Date(character()), thru_dt = as.Date(character())))
  dbWriteTable(con, "dx_long", data.frame(BENE_ID = character(), CLM_ID = character(), dt = as.Date(character()), src = character(), code = character(), dx3 = character()))
  duckdb::duckdb_register(con, "icd_fx", data.frame(code = "S72009"))
  dbWriteTable(con, "ahtn_fill", data.frame(BENE_ID = ids, fill_dt = idx, days_supply = 90, ahtn_class = "ACEI"))
  fu <- build_followup(con); g <- function(id, col) fu[[col]][fu$BENE_ID == id]       # default data end
  expect_equal(g("G1", "itt_end"), d("2023-03-15")); expect_equal(g("G1", "itt_end_reason"), "day 365")   # the old rule would have stopped on 2023-03-02
  expect_equal(g("G1", "itt_end_old"), d("2023-03-02"))
  expect_equal(g("G2", "itt_end"), d("2023-03-31")); expect_equal(g("G2", "itt_end_reason"), "end of data")
  expect_equal(g("G3", "itt_end"), d("2022-09-30")); expect_equal(g("G3", "itt_end_reason"), "loss of Part A/B/D")
})

test_that("add-on/switch-censored sensitivity analysis censors only at the other study drug; discontinuation is descriptive", {
  con <- make_fu_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  fu <- build_followup(con, data_end = d("2019-12-31")); g <- function(id, col) fu[[col]][fu$BENE_ID == id]
  expect_equal(g("F6", "other_type"), "add-on"); expect_equal(g("F6", "as_end"), d("2018-01-20")); expect_equal(g("F6", "as_end_reason"), "add-on")
  expect_equal(g("F6", "tt_status"), "add-on"); expect_equal(g("F6", "tt_time"), 19)
  expect_true(!is.na(g("F6", "hosp_dt")) && is.na(g("F6", "hosp_as")))      # the admission on 2018-03-01 happens after the censor date
  expect_equal(g("F7", "other_type"), "switch"); expect_equal(g("F7", "as_end_reason"), "switch")
  expect_equal(g("F1", "disc_dt"), d("2018-03-01")); expect_equal(g("F1", "tt_status"), "discontinuation")
  expect_equal(g("F1", "as_end"), d("2019-01-01")); expect_equal(g("F1", "as_end_reason"), "day 365")   # discontinuation does NOT censor the sensitivity analysis (A-007)
  expect_equal(g("F1", "hosp_as"), d("2018-02-01"))
  expect_equal(g("F8", "tt_status"), "censored")                            # kept refilling through the window
  expect_equal(g("F9", "tt_status"), "censored"); expect_equal(g("F9", "tt_time"), 150)   # Part D lost before any event could be seen (2018-05-31 minus 2018-01-01)
})

test_that("crude event table counts events and full-follow-up people per arm", {
  con <- make_fu_db(); on.exit(dbDisconnect(con, shutdown = TRUE))
  fu <- build_followup(con, data_end = d("2019-12-31")); ce <- crude_events(fu)
  expect_equal(ce$n, 9)
  expect_equal(ce$hosp_365_itt, 2)                                            # F1 and F6 (F2 outside the window, F3 not observable)
  expect_equal(ce$fracture_365_itt, 1)
  expect_equal(ce$n_full_365, 6)                                              # F3 and F9 (entitlement lost) and F4 (data ends) lack a full year
  expect_equal(ce$hosp_365_addon_switch_censored, 1)                          # F1 only; the F6 admission falls after its add-on censor date
})
