# Purpose: verify source parsing, probability policies and valuation identities.
# All observations below are synthetic; tests never request provider data.
# Run from the project root: source("tests/test_migration_valuation.R").

local({
  for (module in c("issuer_registry.R", "fed_yield_curve.R",
                    "transition_matrix.R", "rating_spreads.R",
                    "migration_valuation.R",
                    "migration_pipeline.R")) {
    source(file.path("R", module), local = TRUE)
  }
  fixture_dir <- tempfile("migration_tests_")
  dir.create(fixture_dir)
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)
  checks <- 0L
  check <- function(condition, label) {
    if (!isTRUE(condition)) stop(paste("FAILED:", label), call. = FALSE)
    checks <<- checks + 1L
  }
  close_to <- function(actual, expected, label) {
    check(isTRUE(all.equal(unname(actual), unname(expected),
                             tolerance = 1e-10)),
          label)
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = base::identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  states <- credit_states()
  percentages <- matrix(0, 7, 9, dimnames = list(head(states, -1L),
                                                c(states, "NR")))
  for (i in seq_len(7L)) {
    percentages[i, i] <- 80
    percentages[i, if (i == 7L) 6L else i + 1L] <- 8
    percentages[i, "D"] <- 2
    percentages[i, "NR"] <- 10
  }
  published <- data.frame(from_rating = rownames(percentages), percentages,
                           row.names = NULL, check.names = FALSE)
  conditional <- build_transition_matrix(published, "condition_on_observed")
  held <- build_transition_matrix(published, "nr_to_initial_rating")
  close_to(rowSums(conditional$matrix), rep(1, 8),
           "all model probability rows sum to one")
  close_to(conditional$matrix["B", "D"], 2 / 90,
           "conditioning on observed outcomes changes the default probability")
  close_to(held$matrix["B", "D"], 0.02,
           "holding NR at its initial grade preserves normalized default mass")
  close_to(held$matrix["B", "B"], 0.9,
           "the hold-grade policy allocates NR to the original grade")
  close_to(conditional$matrix["D", ], as.numeric(states == "D"),
           "default is an absorbing model state")
  check(!"NR" %in% colnames(conditional$matrix),
        "NR is an unobserved outcome, not a ninth ordered credit state")
  rounded <- published
  rounded$AAA[1] <- rounded$AAA[1] + 0.01
  corrected <- build_transition_matrix(rounded, "condition_on_observed")
  close_to(corrected$audit$rounding_error_pp[1], 0.01,
           "small source rounding discrepancies are retained in the audit")
  bad <- published
  bad$AAA[1] <- bad$AAA[1] + 1
  expect_error(build_transition_matrix(bad, "condition_on_observed"),
               "total 100")
  bad <- published
  bad$AAA[1] <- -1
  expect_error(build_transition_matrix(bad, "condition_on_observed"), "between")
  expect_error(build_transition_matrix(published, "silently_drop_nr"),
               "explicit")
  expect_error(build_transition_matrix(published, "condition_on_observed", 1),
               "0.05")
  bad <- published
  bad[1, c(states, "NR")] <- 0
  bad$NR[1] <- 100
  expect_error(build_transition_matrix(bad, "condition_on_observed"), "only NR")
  all_nr_held <- build_transition_matrix(bad, "nr_to_initial_rating")
  close_to(all_nr_held$matrix["AAA", "AAA"],
           1, "an all-NR row requires an explicit hold-grade assumption")

  # Include deviations and a later horizon to catch incorrect extraction.
  cell_row <- function(cells, tag = "td") {
    paste0("<tr>", paste0("<", tag, ">", cells, "</", tag, ">", collapse = ""),
            "</tr>")
  }
  table_rows <- vapply(seq_len(7L), function(i) {
    paste0(cell_row(c(published$from_rating[i],
                      as.character(unlist(published[i, -1L])))),
            cell_row(c("", rep("(9.99)", 9L))))
  }, character(1))
  html <- paste0(
    "<html><body><table><tr><th class='tableTitle'>",
    "Global corporate average transition rates (2000-2023) (%)</th></tr>",
    cell_row(c("From/to", states, "NR"), "th"),
    "<tr><th>One-year</th></tr>", paste0(table_rows, collapse = ""),
    "<tr><th>Three-year</th></tr>",
    cell_row(c("AAA", 100, rep(0, 8))), "</table></body></html>"
  )
  sp_fixture <- file.path(fixture_dir, "study.html")
  writeLines(html, sp_fixture)
  parsed <- read_sp_transition_table(sp_fixture, 2000L, 2023L)
  close_to(as.matrix(parsed[-1L]), as.matrix(published[-1L]),
           "the parser selects the one-year mean probability rows")
  escaped <- gsub("&", "&amp;", html, fixed = TRUE)
  escaped <- gsub("<", "&lt;", escaped, fixed = TRUE)
  escaped <- gsub(">", "&gt;", escaped, fixed = TRUE)
  payload <- list(
    props = list(pageProps = list(props = list(list(html = escaped))))
  )
  embedded_fixture <- file.path(fixture_dir, "embedded.html")
  writeLines(paste0("<html><script id='__NEXT_DATA__' type='application/json'>",
                    jsonlite::toJSON(payload, auto_unbox = TRUE),
                    "</script></html>"), embedded_fixture)
  parsed_embedded <- read_sp_transition_table(embedded_fixture, 2000L, 2023L)
  close_to(as.matrix(parsed_embedded[-1L]), as.matrix(published[-1L]),
           "the public JSON/escaped-HTML layout is supported")
  expect_error(read_sp_transition_table(sp_fixture, 1981L, 2025L), "not found")
  changed_fixture <- file.path(fixture_dir, "changed.html")
  writeLines(sub("<td>80</td>", "<td>broken</td>", html), changed_fixture)
  expect_error(read_sp_transition_table(changed_fixture, 2000L, 2023L),
               "Malformed")

  date <- as.Date("2024-01-16")
  series <- rating_spread_series()
  spread_history <- data.frame(observation_date = date + 0:2)
  for (id in unname(series)) spread_history[[id]] <- c(1, 2, NA_real_)
  selected <- select_rating_spreads(spread_history, date + 2L)
  close_to(selected$spread_decimal_proxy, rep(0.02, 7),
           "source percent spreads become decimal model proxies")
  check(all(selected$observation_date == date + 1L),
        "an all-missing calendar row is not a market observation")
  partial <- spread_history
  partial[2, unname(series)[1]] <- NA_real_
  expect_error(select_rating_spreads(partial, date + 2L), "latest.*missing")
  expect_error(select_rating_spreads(spread_history, date + 9L), "stale")
  spread_csv <- file.path(fixture_dir, "spreads.csv")
  readr::write_csv(spread_history, spread_csv)
  check(nrow(read_rating_spread_history(spread_csv)) == 3L,
        "historical missing spread values survive CSV import")
  readr::write_csv(rbind(spread_history, spread_history[1, ]), spread_csv)
  expect_error(read_rating_spread_history(spread_csv), "duplicate")

  registry <- data.frame(issuer_id = "TEST", currency = "USD",
                          rating_bucket = "B",
                          notional_usd_million = 1, maturity_years = 5)
  curve <- data.frame(observation_date = date, maturity_years = c(1, 5),
                       zero_rate_continuous = 0.04)
  spreads <- data.frame(observation_date = date,
                         rating_bucket = names(series),
                         spread_decimal_proxy = 0.01)
  value <- function(p = conditional$matrix, r = 0.4, portfolio = registry,
                     zeros = curve, credit = spreads, horizon = 1) {
    value_migration_states(portfolio, zeros, credit, p, r, horizon)
  }
  flat <- value()
  close_to(flat$issuer_summary$initial_value_usd_million, 0.7788007830714049,
           "five-year inception value discounts the full five years")
  close_to(flat$issuer_summary$no_migration_value_usd_million,
           0.8187307530779818,
           "one-year horizon value discounts four remaining years")
  close_to(flat$issuer_summary$forward_rate_continuous, 0.04,
           "a flat zero curve gives the same forward rate")
  close_to(flat$state_values[1, "D"], 0.4,
           "default is recovery of face paid at the horizon")
  pd <- 2 / 90
  close_to(flat$issuer_summary$expected_value_usd_million,
           (1 - pd) * 0.8187307530779818 + pd * 0.4,
           "expected value weights all survival and default outcomes")
  sloped <- curve
  sloped$zero_rate_continuous <- c(0.02, 0.06)
  slope_value <- value(zeros = sloped)
  close_to(slope_value$issuer_summary$forward_rate_continuous, 0.07,
           "a sloped curve uses the implied one-to-five-year forward rate")
  close_to(slope_value$issuer_summary$no_migration_value_usd_million,
           0.7261490370736909, "forward discounting matches the reference")
  zero_curve <- curve
  zero_curve$zero_rate_continuous <- 0
  zero_spreads <- spreads
  zero_spreads$spread_decimal_proxy <- 0
  zero_value <- value(zeros = zero_curve, credit = zero_spreads)
  close_to(zero_value$issuer_summary$expected_credit_loss_usd_million,
           pd * (1 - 0.4), "zero-rate limit reduces to PD times LGD times face")
  identity_transition <- diag(8)
  dimnames(identity_transition) <- list(states, states)
  unchanged <- value(p = identity_transition)
  close_to(unchanged$issuer_summary$expected_credit_loss_usd_million, 0,
           "no migrations or defaults imply zero loss versus no migration")
  defaults <- identity_transition
  defaults[,] <- 0
  defaults[, "D"] <- 1
  close_to(value(p = defaults)$portfolio_summary$expected_value_usd_million,
           0.4,
           "certain default values the entire portfolio at recovery")
  close_to(value(r = 0)$state_values[1, "D"], 0,
           "zero recovery is a valid endpoint")
  close_to(value(r = 1)$state_values[1, "D"], 1,
           "full recovery is a valid endpoint")
  split <- registry[c(1, 1), ]
  split$issuer_id <- c("PART_A", "PART_B")
  split$notional_usd_million <- c(0.4, 0.6)
  split_value <- value(portfolio = split)$portfolio_summary
  close_to(split_value$expected_value_usd_million,
           flat$portfolio_summary$expected_value_usd_million,
           "splitting an exposure preserves its expected value")
  expect_error(value(r = 1.1), "recovery")
  expect_error(value(horizon = 2), "one-year")
  bad <- registry
  bad$maturity_years <- 1
  expect_error(value(portfolio = bad), "remaining maturity")
  bad <- spreads
  bad$observation_date <- date + 1L
  expect_error(value(credit = bad), "shared date")
  expect_error(value(zeros = curve[-1L, ]), "exact tenor")
  bad <- identity_transition
  bad["D", ] <- rep(1 / 8, 8)
  expect_error(value(p = bad), "absorbing D")
  expect_error(validate_transition_matrix(identity_transition, Inf),
               "tolerance")
  negative_spreads <- zero_spreads
  negative_spreads$spread_decimal_proxy <- -0.01
  check(all(value(zeros = zero_curve, credit = negative_spreads)$state_values[
    , head(states, -1L)] > 1), "finite negative spreads are preserved")

  # Offline integration: source bytes, shared dates, snapshots and cleanup.
  project <- file.path(fixture_dir, "project")
  dir.create(file.path(project, "config"), recursive = TRUE)
  config_dir <- file.path(project, "config")
  seed_dates <- readr::read_csv(
    file.path("config", "issuers.csv"),
    col_types = readr::cols_only(rating_reviewed_on = readr::col_date()),
    show_col_types = FALSE
  )
  seed <- read_issuer_registry(file.path("config", "issuers.csv"),
                                max(seed_dates$rating_reviewed_on))[1:2, ]
  seed$rating_source_date <- as.Date("2023-12-01")
  seed$rating_reviewed_on <- as.Date("2024-01-17")
  readr::write_csv(seed, file.path(config_dir, "issuers.csv"))
  descriptor <- data.frame(
    study_start_year = 2000L, study_end_year = 2023L,
    published_on = as.Date("2024-01-10"), reviewed_on = as.Date("2024-01-17"),
    review_due_on = as.Date("2025-04-30"),
    source_url = "https://www.spglobal.com/ratings/synthetic-test-fixture"
  )
  descriptor_path <- file.path(config_dir, "transition_source.csv")
  readr::write_csv(descriptor, descriptor_path)
  expect_error(read_transition_source(descriptor_path, as.Date("2025-05-01")),
               "expired")
  assumptions <- data.frame(
    horizon_years = 1, recovery_rate = 0.4,
    nr_policy = "condition_on_observed",
    spread_policy = "flat_index_oas_continuous_proxy",
    recovery_note = "Synthetic model assumption"
  )
  assumptions_path <- file.path(config_dir, "valuation_assumptions.csv")
  readr::write_csv(assumptions, assumptions_path)
  bad <- assumptions
  bad$recovery_rate <- -0.1
  bad_path <- file.path(fixture_dir, "bad_assumptions.csv")
  readr::write_csv(bad, bad_path)
  expect_error(read_valuation_assumptions(bad_path), "Invalid assumptions")

  fed_fixture <- file.path(fixture_dir, "fed.csv")
  writeLines(c(
    "Synthetic test source; not market data.",
    "Zero-coupon yield,Continuously Compounded,SVENYXX",
    paste(c("Date", sprintf("SVENY%02d", 1:30)), collapse = ","),
    paste(c("2024-01-15", rep(4, 30)), collapse = ","),
    paste(c("2024-01-16", rep(4, 30)), collapse = ",")
  ), fed_fixture)
  integration_spreads <- data.frame(
    observation_date = as.Date(c("2024-01-15", "2024-01-16", "2024-01-17"))
  )
  for (id in unname(series)) integration_spreads[[id]] <- c(1, 1.1, 1.2)
  fred_fixture <- file.path(fixture_dir, "fred.csv")
  readr::write_csv(integration_spreads, fred_fixture)
  shared_partial <- integration_spreads
  shared_partial[2, unname(series)[1]] <- NA_real_
  expect_error(align_credit_market_inputs(
    read_fed_yield_history(fed_fixture), shared_partial, as.Date("2024-01-17")
  ), "latest.*missing")
  no_overlap <- read_fed_yield_history(fed_fixture)
  no_overlap$Date <- no_overlap$Date - 365L
  expect_error(align_credit_market_inputs(
    no_overlap, integration_spreads, as.Date("2024-01-17")
  ), "No shared")
  fake_download <- function(url, path, query = list()) {
    source <- if (grepl("spglobal", url, fixed = TRUE)) {
      sp_fixture
    } else {
      fred_fixture
    }
    file.copy(source, path)
    data.frame(source_url = url, downloaded_at_utc = "2024-01-18T12:00:00Z",
                 http_status = 200L, source_md5 = unname(tools::md5sum(path)))
  }
  fake_fed <- function(project_dir, as_of_date, max_age_days) {
    history <- read_fed_yield_history(fed_fixture)
    curve <- select_fed_yield_curve(history, as_of_date, max_age_days)
    list(raw_path = fed_fixture, metadata = data.frame(
      observation_date = curve$observation_date[1],
      source_url = "https://example.org/fed",
      downloaded_at_utc = "2024-01-18T12:00:00Z",
      raw_md5 = unname(tools::md5sum(fed_fixture)),
      raw_file = "synthetic-fed.csv"
    ))
  }
  run <- function(downloader = fake_download) {
    run_migration_valuation(
      project, as_of_date = as.Date("2024-01-17"),
      review_date = as.Date("2024-01-17"), input_downloader = downloader,
      curve_downloader = fake_fed
    )
  }
  first <- run()
  check(first$metadata$market_observation_date == as.Date("2024-01-16") &&
          first$metadata$latest_spread_observation == as.Date("2024-01-17"),
        "shared market date and latest feed date remain distinct")
  check(nrow(first$sensitivity) == 6L &&
          sum(first$sensitivity$is_baseline) == 1L,
        "recovery and NR sensitivities identify exactly one primary case")
  check(all(first$issuer_summary$remaining_years_at_horizon == 4),
        "configured five-year exposures have four years remaining")
  saved <- readRDS(file.path(first$snapshot_dir, "model_inputs.rds"))
  close_to(saved$transition, conditional$matrix,
           "saved inputs preserve precision and state ordering")
  second <- run()
  check(first$snapshot_dir != second$snapshot_dir &&
          file.exists(file.path(first$snapshot_dir, "portfolio_summary.csv")),
        "new runs preserve old valuation snapshots")
  failed_download <- function(url, path, query = list()) {
    stop("Synthetic provider outage")
  }
  expect_error(run(failed_download), "Synthetic provider outage")
  completed_processed <- list.dirs(
    file.path(project, "data", "processed", "migration_valuation"),
    recursive = FALSE
  )
  completed_raw <- list.dirs(
    file.path(project, "data", "raw", "migration_valuation"), recursive = FALSE
  )
  check(length(completed_processed) == 2L && length(completed_raw) == 2L,
        "failed runs clean partial output and preserve completed snapshots")
  cat(sprintf("Passed %d assertions; no network requests were made.\n", checks))
})
