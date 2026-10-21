# Run from the project root: Rscript tests/testthat.R
library(testthat)
res <- test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
