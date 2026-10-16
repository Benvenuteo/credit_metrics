# Purpose: verify source parsing, date selection, units, and failure cases.
# Run from the project root: source("tests/test_fed_yield_curve.R").
# All fixtures are synthetic; these tests make no network requests.

local({
  source(file.path("R", "fed_yield_curve.R"), local = TRUE)
  fixture_dir <- tempfile("fed_tests_")
  dir.create(fixture_dir)
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)
  checks <- 0L

  check <- function(condition, label) {
    if (!isTRUE(condition)) {
      stop(paste("FAILED:", label), call. = FALSE)
    }
    checks <<- checks + 1L
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  fixture_lines <- c(
    "Synthetic test data; not market observations.", "",
    "Series,Compounding Convention,Mnemonic(s)",
    "Zero-coupon yield,Continuously Compounded,SVENYXX", "",
    "Date,SVENY01,SVENY04,SVENY05",
    "2024-01-04,4.2,NA,4.5",
    "2024-01-02,4.0,4.2,4.3",
    "2024-01-03,4.1,4.3,4.4"
  )
  make_fixture <- function(lines = fixture_lines) {
    path <- tempfile("fixture_", tmpdir = fixture_dir, fileext = ".csv")
    writeLines(lines, path, useBytes = TRUE)
    path
  }

  history <- read_fed_yield_history(make_fixture(), c(5, 1, 4))
  check(identical(names(history),
                  c("Date", "SVENY01", "SVENY04", "SVENY05")),
        "maturity columns are selected and sorted")
  check(identical(history$Date,
                  as.Date(c("2024-01-02", "2024-01-03", "2024-01-04"))),
        "observation dates are parsed and sorted")
  check(is.na(history$SVENY04[3]), "historical missing values are retained")

  curve <- select_fed_yield_curve(history, as.Date("2024-01-03"))
  check(identical(curve$maturity_years, c(1L, 4L, 5L)),
        "one curve row exists per maturity")
  check(all(curve$observation_date == as.Date("2024-01-03")),
        "future observations are excluded by the cutoff")
  check(isTRUE(all.equal(curve$zero_rate_continuous,
                         c(0.041, 0.043, 0.044))),
        "source percentages are converted to decimal rates")
  check(isTRUE(all.equal(curve$discount_factor,
                         exp(-c(0.041, 0.172, 0.220)))),
        "discount factors use continuous compounding")

  complete_history <- history[1:2, ]
  boundary <- select_fed_yield_curve(
    complete_history, as.Date("2024-01-05"), max_age_days = 2L
  )
  check(nrow(boundary) == 3L, "the freshness boundary is inclusive")
  expect_error(select_fed_yield_curve(
    complete_history, as.Date("2024-01-06"), max_age_days = 2L
  ), "stale")
  expect_error(select_fed_yield_curve(history, as.Date("2024-01-04")),
               "latest.*missing")
  expect_error(select_fed_yield_curve(history, as.Date("2024-01-01")),
               "No observations")

  negative_curve <- select_fed_yield_curve(
    data.frame(Date = as.Date("2024-01-03"), SVENY01 = -0.5),
    as.Date("2024-01-03")
  )
  check(negative_curve$discount_factor > 1,
        "negative rates are preserved; discount factors may exceed 1")
  zero_curve <- select_fed_yield_curve(
    data.frame(Date = as.Date("2024-01-03"), SVENY01 = 0),
    as.Date("2024-01-03")
  )
  check(zero_curve$discount_factor == 1, "zero rates give a unit discount factor")

  bad_number <- fixture_lines
  bad_number[9] <- "2024-01-03,broken,4.3,4.4"
  expect_error(read_fed_yield_history(make_fixture(bad_number), c(1, 4, 5)),
               "malformed")
  bad_date <- fixture_lines
  bad_date[9] <- "2024-99-03,4.1,4.3,4.4"
  expect_error(read_fed_yield_history(make_fixture(bad_date), c(1, 4, 5)),
               "malformed")
  duplicate_date <- fixture_lines
  duplicate_date[9] <- "2024-01-02,4.1,4.3,4.4"
  expect_error(read_fed_yield_history(make_fixture(duplicate_date),
                                     c(1, 4, 5)), "unique")
  expect_error(read_fed_yield_history(make_fixture(), 30),
               "Missing source columns")
  expect_error(read_fed_yield_history(make_fixture("<html>Unavailable</html>")),
               "header")
  changed_convention <- sub("Continuously Compounded", "Coupon-Equivalent",
                            fixture_lines, fixed = TRUE)
  expect_error(read_fed_yield_history(make_fixture(changed_convention),
                                     c(1, 4, 5)), "continuously compounded")
  infinite_yield <- fixture_lines
  infinite_yield[9] <- "2024-01-03,Inf,4.3,4.4"
  expect_error(read_fed_yield_history(make_fixture(infinite_yield),
                                     c(1, 4, 5)), "infinite")

  for (maturities in list(c(1, 1), 0, 31, 1.5, NA_real_, numeric())) {
    expect_error(validate_fed_maturities(maturities), "unique integers")
  }
  expect_error(select_fed_yield_curve(history, "2024-01-03"), "single.*Date")
  expect_error(select_fed_yield_curve(history, as.Date(NA)), "single.*Date")
  for (age in list(-1, 0.5, Inf, NA_real_)) {
    expect_error(select_fed_yield_curve(history, as.Date("2024-01-03"), age),
                 "non-negative integer")
  }
  expect_error(download_fed_yield_curve(project_dir = fixture_dir,
                                        source_url = "http://example.com"),
               "HTTPS")
  expect_error(download_fed_yield_curve(project_dir = fixture_dir,
                                        max_age_days = -1),
               "non-negative integer")
  cat(sprintf("Passed %d assertions; no network requests were made.\n", checks))
})
