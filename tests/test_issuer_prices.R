# Purpose: check rating provenance, return alignment and data-quality failures.
# Run from the project root: source("tests/test_issuer_prices.R").
# Synthetic fixtures and an injected downloader keep all checks offline.

local({
  source(file.path("R", "issuer_registry.R"), local = TRUE)
  source(file.path("R", "issuer_prices.R"), local = TRUE)
  fixture_dir <- tempfile("issuer_tests_")
  dir.create(fixture_dir)
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)
  checks <- 0L
  check <- function(condition, label) {
    if (!isTRUE(condition)) stop(paste("FAILED:", label), call. = FALSE)
    checks <<- checks + 1L
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  seed_path <- file.path("config", "issuers.csv")
  seed_dates <- readr::read_csv(
    seed_path, col_types = readr::cols_only(rating_reviewed_on = readr::col_date()),
    show_col_types = FALSE
  )
  seed <- read_issuer_registry(
    seed_path, review_as_of_date = max(seed_dates$rating_reviewed_on)
  )
  check(sum(seed$notional_usd_million) == 100,
        "the historical portfolio design retains USD 100 million face value")
  check(seed$ticker[seed$issuer_id == "VTOL"] == "VTOL" &&
          seed$exchange[seed$issuer_id == "VTOL"] == "NYSE",
        "Bristow uses its current post-merger listing")
  check(identical(sp_rating_bucket(c("AAA", "AA-", "A+", "BBB+", "BB-", "B+",
                                      "CCC-", "CC", "C", "SD", "D")),
                  c("AAA", "AA", "A", "BBB", "BB", "B", "CCC/C", "CCC/C",
                    "CCC/C", "D", "D")), "notches map to explicit broad buckets")
  expect_error(sp_rating_bucket("NR"), "NR")
  expect_error(sp_rating_bucket("Baa1"), "recognized")

  registry <- seed[1:3, ]
  registry$rating_source_date <- as.Date("2023-12-01")
  registry$rating_reviewed_on <- as.Date("2024-01-17")
  write_registry <- function(x = registry) {
    path <- tempfile("registry_", tmpdir = fixture_dir, fileext = ".csv")
    readr::write_csv(x, path)
    path
  }
  registry_path <- write_registry()
  check(nrow(read_issuer_registry(registry_path, as.Date("2024-02-16"))) == 3L,
        "a 30-day review age is accepted at the boundary")
  expect_error(read_issuer_registry(registry_path, as.Date("2024-02-17")),
               "review is stale")
  expect_error(read_issuer_registry(registry_path, as.Date("2024-01-16")),
               "future")
  bad <- registry
  bad$rating_bucket[1] <- "A"
  expect_error(read_issuer_registry(write_registry(bad), as.Date("2024-01-17")),
               "does not match")
  bad <- registry
  bad$rating_type[1] <- "senior_secured_issue"
  expect_error(read_issuer_registry(write_registry(bad), as.Date("2024-01-17")),
               "issuer ratings")
  bad <- registry
  bad$ticker[2] <- bad$ticker[1]
  expect_error(read_issuer_registry(write_registry(bad), as.Date("2024-01-17")),
               "unique")
  bad <- registry
  bad$notional_usd_million[1] <- -1
  expect_error(read_issuer_registry(write_registry(bad), as.Date("2024-01-17")),
               "positive")
  bad <- registry
  bad$currency[1] <- "EUR"
  expect_error(read_issuer_registry(write_registry(bad), as.Date("2024-01-17")),
               "USD")
  malformed <- readLines(registry_path)
  malformed[2] <- sub("2023-12-01", "2023-99-01", malformed[2], fixed = TRUE)
  malformed_path <- tempfile(tmpdir = fixture_dir, fileext = ".csv")
  writeLines(malformed, malformed_path)
  expect_error(read_issuer_registry(malformed_path, as.Date("2024-01-17")),
               "malformed")

  check(default_equity_cutoff(as.POSIXct("2024-01-18 01:00:00", tz = "UTC")) ==
          as.Date("2024-01-16"), "cutoff uses the New York date rather than UTC")
  check(default_equity_cutoff(as.POSIXct("2024-01-17 23:00:00", tz = "UTC")) ==
          as.Date("2024-01-16"), "today remains excluded after market close")
  expect_error(default_equity_cutoff("2024-01-17"), "POSIXt")

  dates <- as.Date(c("2024-01-02", "2024-01-03", "2024-01-04", "2024-01-05",
                     "2024-01-08", "2024-01-09", "2024-01-10", "2024-01-11",
                     "2024-01-12", "2024-01-16", "2024-01-17"))
  a <- c(0.01, -0.02, 0.03, 0, -0.01, 0.02, -0.03, 0.015, 0.025, 0.005)
  b <- c(-0.005, 0.025, -0.01, 0.015, 0.02, -0.02, 0.01, 0.03, -0.015, 0.005)
  c_returns <- c(0.02, 0.01, 0.015, -0.02, 0.005, -0.01, 0.025, -0.005, 0.03, -0.015)
  make_prices <- function(log_returns, i) {
    adjusted <- 100 * exp(c(0, cumsum(log_returns)))
    data.frame(issuer_id = registry$issuer_id[i], ticker = registry$ticker[i],
               date = dates, open = adjusted * 1.01, high = adjusted * 1.02,
               low = adjusted * 0.99, close = adjusted * 1.01, volume = 1000,
               adjusted = adjusted)
  }
  prices <- rbind(make_prices(a, 1), make_prices(b, 2), make_prices(c_returns, 3))
  analyze <- function(x = prices, cutoff = max(dates), coverage = 0.75,
                        minimum = 5L, age = 7L) {
    prepare_issuer_prices(x, registry, min(dates), cutoff,
                          max_age_days = age, min_observations = minimum,
                          min_coverage = coverage)
  }
  full <- analyze()
  check(nrow(full$returns) == 10L && all(full$sample_audit$retained),
        "a complete panel retains every eligible return")
  check(isTRUE(all.equal(full$returns$INTC, a, tolerance = 1e-12)),
        "log returns are recovered from Adjusted, without second adjustment")
  centered_a <- a - mean(a)
  centered_b <- b - mean(b)
  expected_correlation <- sum(centered_a * centered_b) /
    sqrt(sum(centered_a ^ 2) * sum(centered_b ^ 2))
  check(abs(full$correlation["INTC", "AMZN"] - expected_correlation) < 1e-12,
        "Pearson correlation agrees with the independent centered-sum formula")
  check(identical(colnames(full$correlation), registry$issuer_id),
        "matrix ordering follows the registry")
  check(full$min_eigenvalue >= -1e-8, "the complete-sample matrix is PSD")

  gap_date <- dates[5]
  gap <- prices[!(prices$issuer_id == "AMZN" & prices$date == gap_date), ]
  with_gap <- analyze(gap)
  check(!any(with_gap$returns$date %in% dates[5:6]),
        "a missing source row excludes both the gap and mismatched next interval")
  next_interval <- with_gap$sample_audit[with_gap$sample_audit$date == dates[6], ]
  check(next_interval$missing_returns == 0L && !next_interval$matching_start_dates,
        "finite returns with different start dates cannot be correlated together")
  check(nrow(with_gap$returns) == 8L &&
          with_gap$quality$common_coverage[1] == 0.8,
        "excluded intervals remain visible in coverage statistics")
  expect_error(analyze(gap, coverage = 0.95), "coverage")
  missing <- prices
  missing$adjusted[missing$issuer_id == "AMZN" & missing$date == gap_date] <- NA_real_
  with_na <- analyze(missing)
  check(!any(with_na$returns$date %in% dates[5:6]),
        "an explicit NA is not interpolated or removed before differencing")
  check(with_na$quality$missing_adjusted[2] == 1L,
        "missing prices are counted in the quality report")
  latest_na <- prices
  latest_na$adjusted[latest_na$issuer_id == "INTC" & latest_na$date == max(dates)] <- NA_real_
  expect_error(analyze(latest_na), "latest price is missing")
  expect_error(analyze(prices, cutoff = max(dates) + 8L), "stale")
  expect_error(analyze(prices, minimum = 500L), "at least 500")
  expect_error(analyze(rbind(prices, prices[1, ])), "Duplicate")
  bad <- prices
  bad$adjusted[1] <- 0
  expect_error(analyze(bad), "positive")
  bad$adjusted[1] <- Inf
  expect_error(analyze(bad), "finite")
  bad <- prices
  bad$ticker[1] <- "WRONG"
  expect_error(analyze(bad), "does not match")
  bad <- prices
  bad$adjusted[bad$issuer_id == "INTC"] <- 100
  expect_error(analyze(bad), "constant")

  # A genuine large move must remain in the estimation sample and audit.
  extreme <- prices
  extreme$adjusted[extreme$issuer_id == "INTC" & extreme$date >= gap_date] <-
    extreme$adjusted[extreme$issuer_id == "INTC" & extreme$date >= gap_date] * exp(0.5)
  flagged <- analyze(extreme)
  check(nrow(flagged$outliers) == 1L && nrow(flagged$returns) == 10L,
        "extreme returns are flagged without automatic deletion or winsorization")
  truncated <- analyze(prices, cutoff = dates[9])
  check(max(truncated$prices$date) == dates[9] &&
          nrow(truncated$returns) == 8L, "future source rows are excluded")
  check(!inherits(try(validate_issuer_correlation(matrix(c(1, -1, -1, 1), 2)),
                      silent = TRUE), "try-error"), "singular PSD matrices are valid")
  expect_error(validate_issuer_correlation(matrix(c(1, 0.9, 0.9, 0.9, 1, -0.9,
                                                    0.9, -0.9, 1), 3)),
               "positive semidefinite")
  expect_error(validate_issuer_correlation(matrix(c(1, 0.1, 0.2, 1), 2)),
               "symmetric")

  # Exercise the full archive path with an in-memory provider substitute.
  fake_fetcher <- function(ticker, from_date, as_of_date) {
    one <- prices[prices$ticker == ticker, ]
    values <- as.matrix(one[c("open", "high", "low", "close", "volume", "adjusted")])
    colnames(values) <- paste(ticker, c("Open", "High", "Low", "Close", "Volume",
                                       "Adjusted"), sep = ".")
    xts::xts(values, order.by = one$date)
  }
  exported <- fake_fetcher("INTC", min(dates), max(dates))
  parsed <- parse_yahoo_prices(exported, "INTC", "INTC")
  check(isTRUE(all.equal(parsed$adjusted, prices$adjusted[prices$issuer_id == "INTC"])),
        "the parser selects the named Adjusted column")
  expect_error(parse_yahoo_prices(exported[, -6], "INTC", "INTC"), "incomplete")
  expect_error(parse_yahoo_prices(exported, "AMZN", "AMZN"), "incomplete")
  project <- file.path(fixture_dir, "project")
  dir.create(file.path(project, "config"), recursive = TRUE)
  file.copy(registry_path, file.path(project, "config", "issuers.csv"))
  run <- function(fetcher = fake_fetcher) {
    download_issuer_prices(
      project_dir = project, from_date = min(dates), as_of_date = max(dates),
      min_observations = 5L, min_coverage = 0.95,
      review_as_of_date = as.Date("2024-01-17"), price_fetcher = fetcher
    )
  }
  first <- run()
  second <- run()
  check(first$snapshot_dir != second$snapshot_dir &&
          file.exists(file.path(first$snapshot_dir, "correlation.csv")),
        "a subsequent run does not overwrite the previous snapshot")
  check(identical(names(readRDS(first$raw_path)), registry$issuer_id),
        "the library source exports are preserved for every issuer")
  check(identical(unname(tools::md5sum(first$raw_path)),
                  first$metadata$source_exports_md5), "source fingerprint is recorded")
  check(identical(unname(tools::md5sum(file.path(dirname(first$raw_path), "issuers.csv"))),
                  first$metadata$registry_md5), "the exact registry vintage is archived")
  saved <- readr::read_csv(file.path(first$snapshot_dir, "returns.csv"),
                            show_col_types = FALSE)
  check(isTRUE(all.equal(saved$INTC, a, tolerance = 1e-12)),
        "saved returns round-trip without losing calculation precision")
  expect_error(run(function(...) stop("Synthetic provider failure")),
               "Synthetic provider failure")
  check(length(list.dirs(file.path(project, "data", "processed", "issuer_prices"),
                          recursive = FALSE)) == 2L,
        "a failed download leaves no successful-looking processed snapshot")
  expect_error(download_issuer_prices(
    project_dir = project, from_date = min(dates), as_of_date = min(dates),
    price_fetcher = function(...) stop("should not run")
  ), "must precede")
  cat(sprintf("Passed %d assertions; no network requests were made.\n", checks))
})
