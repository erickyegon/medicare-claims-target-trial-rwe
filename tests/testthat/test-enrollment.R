test_that("monthly Part A/B/D flags and continuous spans are built correctly", {
  con <- new_con(); on.exit(dbDisconnect(con, shutdown = TRUE))
  ab <- months_between("2017-01-01", "2019-12-01")
  dm <- setdiff(months_between("2017-03-01", "2019-12-01"), as.Date("2018-05-01"))   # Part D starts March 2017 and has a one-month gap in May 2018
  dbWriteTable(con, "bene", bind_rows(
    mk_bene("E1", "1940-01-01", ab, dm),
    mk_bene("E2", "1940-01-01", months_between("2016-01-01", "2016-06-01"), months_between("2016-01-01", "2016-06-01")),
    mk_bene("E3", "1940-01-01", months_between("2016-01-01", "2016-03-01"), as.Date(character()))))   # never has Part D
  build_enrollment(con)

  m <- dbGetQuery(con, "SELECT * FROM enroll_month WHERE BENE_ID = 'E1' ORDER BY month_start")
  expect_equal(nrow(m), 36)                                                     # 3 calendar years x 12 months
  expect_true(all(m$part_a & m$part_b))
  expect_equal(sum(m$part_d), length(dm))
  expect_false(m$part_d[m$month_start == d("2018-05-01")])                      # the gap month
  expect_false(m$part_d[m$month_start == d("2017-02-01")])                      # before Part D starts

  s <- dbGetQuery(con, "SELECT * FROM enroll_span WHERE BENE_ID = 'E1' ORDER BY span_start")
  expect_equal(nrow(s), 2)                                                      # the D gap splits the A+B+D span
  expect_equal(as.character(s$span_start), c("2017-03-01", "2018-06-01"))
  expect_equal(as.character(s$span_end), c("2018-04-30", "2019-12-31"))         # span_end = last day of the last covered month
  expect_equal(s$n_months, c(14, 19))

  ab_s <- dbGetQuery(con, "SELECT * FROM enroll_ab_span WHERE BENE_ID = 'E1'")
  expect_equal(nrow(ab_s), 1); expect_equal(as.character(ab_s$span_start), "2017-01-01"); expect_equal(as.character(ab_s$span_end), "2019-12-31")

  expect_equal(nrow(dbGetQuery(con, "SELECT * FROM enroll_span WHERE BENE_ID = 'E3'")), 0)   # no Part D -> never A+B+D
  expect_equal(nrow(dbGetQuery(con, "SELECT * FROM enroll_ab_span WHERE BENE_ID = 'E3'")), 1)
  # a person-year with no row in the beneficiary file contributes no enrolled months
  expect_equal(dbGetQuery(con, "SELECT count(*) FROM enroll_month WHERE BENE_ID = 'E2' AND year(month_start) = 2017")[[1]], 0)
})
