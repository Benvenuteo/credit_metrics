# Purpose: import and validate the Federal Reserve GSW nominal zero curve.
# Inputs: the Fed CSV or an existing local copy; no API key is required.
# Outputs: a validated curve and immutable raw/processed data snapshots.

#' Validate maturities supported by the Fed's published annual grid.
#' @param maturity_years Unique integer maturities between 1 and 30.
#' @return Sorted integer maturities.
validate_fed_maturities <- function(maturity_years) {
  if (!is.numeric(maturity_years) || !length(maturity_years) ||
      anyNA(maturity_years) || any(!is.finite(maturity_years)) ||
      any(maturity_years != floor(maturity_years)) ||
      any(maturity_years < 1 | maturity_years > 30) ||
      anyDuplicated(maturity_years)) {
    stop("maturity_years must contain unique integers from 1 to 30.",
         call. = FALSE)
  }
  sort(as.integer(maturity_years))
}

#' Validate the analysis cutoff and the permitted publication lag.
#' @param as_of_date A single non-missing Date.
#' @param max_age_days A non-negative integer, measured in calendar days.
#' @return NULL, invisibly; invalid arguments raise an informative error.
validate_fed_cutoff <- function(as_of_date, max_age_days) {
  if (!inherits(as_of_date, "Date") || length(as_of_date) != 1L ||
      is.na(as_of_date) || !is.finite(as.numeric(as_of_date))) {
    stop("as_of_date must be a single non-missing Date.", call. = FALSE)
  }
  if (!is.numeric(max_age_days) || length(max_age_days) != 1L ||
      is.na(max_age_days) || !is.finite(max_age_days) ||
      max_age_days < 0 || max_age_days != floor(max_age_days)) {
    stop("max_age_days must be a non-negative integer.", call. = FALSE)
  }
  invisible(NULL)
}

#' Read the zero-coupon columns from a downloaded Fed CSV.
#' @param path Existing CSV file, including the Fed's metadata preamble.
#' @param maturity_years Integer maturities between 1 and 30.
#' @return A data frame with Date and the requested SVENY columns.
#' @details Historical missing yields are retained. Malformed values,
#'   duplicate dates, and a changed compounding convention are rejected.
read_fed_yield_history <- function(path, maturity_years = 1:30) {
  maturity_years <- validate_fed_maturities(maturity_years)
  if (!is.character(path) || length(path) != 1L || is.na(path) ||
      !file.exists(path) || dir.exists(path)) {
    stop("path must point to an existing CSV file.", call. = FALSE)
  }

  preview <- readr::read_lines(path, n_max = 100, progress = FALSE)
  header_row <- which(grepl("^Date,", trimws(preview)))
  if (length(header_row) != 1L) {
    stop("The Fed CSV Date header was not found in the first 100 lines.",
         call. = FALSE)
  }
  if (!any(grepl(
    "^Zero-coupon yield,Continuously Compounded,SVENYXX$",
    trimws(preview)
  ))) {
    stop("The source does not confirm continuously compounded SVENY yields.",
         call. = FALSE)
  }

  yield_columns <- sprintf("SVENY%02d", maturity_years)
  header <- readr::read_csv(
    I(preview[header_row]), n_max = 0,
    col_types = readr::cols(.default = readr::col_character()),
    name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  )
  missing_columns <- setdiff(c("Date", yield_columns), names(header))
  if (length(missing_columns)) {
    stop(paste("Missing source columns:",
               paste(missing_columns, collapse = ", ")), call. = FALSE)
  }

  parsers <- c(
    list(Date = readr::col_date(format = "%Y-%m-%d")),
    setNames(rep(list(readr::col_double()), length(yield_columns)),
             yield_columns)
  )
  # Inspect parser diagnostics explicitly rather than silently creating NAs.
  history <- suppressWarnings(readr::read_csv(
    path, skip = header_row - 1L,
    col_types = do.call(readr::cols_only, parsers),
    na = c("", "NA", "N/A"), name_repair = "check_unique",
    show_col_types = FALSE, progress = FALSE, lazy = FALSE
  ))
  if (nrow(readr::problems(history))) {
    stop("The Fed CSV contains malformed dates or numeric values.",
         call. = FALSE)
  }
  if (!nrow(history) || anyNA(history$Date) || anyDuplicated(history$Date)) {
    stop("The Fed CSV must contain non-missing, unique observation dates.",
         call. = FALSE)
  }
  yields <- as.matrix(history[, yield_columns, drop = FALSE])
  if (any(!is.finite(yields) & !is.na(yields))) {
    stop("The Fed CSV contains infinite yield values.", call. = FALSE)
  }
  history <- as.data.frame(history)
  history[order(history$Date), c("Date", yield_columns), drop = FALSE]
}

#' Select and validate the latest curve on or before an analysis date.
#' @param history Output of read_fed_yield_history().
#' @param as_of_date A single Date defining the analysis cutoff.
#' @param max_age_days Maximum observation age in calendar days.
#' @return A data frame with one row per maturity and explicit rate units.
#' @details Selects one complete date, without mixing maturities across dates.
#'   Incomplete latest observations cause an error, not an older-date fallback.
select_fed_yield_curve <- function(history, as_of_date = Sys.Date(),
                                   max_age_days = 14L) {
  validate_fed_cutoff(as_of_date, max_age_days)
  if (!is.data.frame(history) || !inherits(history$Date, "Date") ||
      anyNA(history$Date) || anyDuplicated(history$Date)) {
    stop("history must have a Date column with unique, non-missing dates.",
         call. = FALSE)
  }
  yield_columns <- grep("^SVENY[0-9]{2}$", names(history), value = TRUE)
  if (!length(yield_columns) ||
      !all(vapply(history[yield_columns], is.numeric, logical(1)))) {
    stop("history must contain numeric SVENY columns.", call. = FALSE)
  }
  maturity_years <- as.integer(sub("^SVENY", "", yield_columns))
  validate_fed_maturities(maturity_years)
  column_order <- order(maturity_years)
  maturity_years <- maturity_years[column_order]
  yield_columns <- yield_columns[column_order]

  eligible <- history[history$Date <= as_of_date, , drop = FALSE]
  if (!nrow(eligible)) {
    stop("No observations are available on or before as_of_date.",
         call. = FALSE)
  }
  latest <- eligible[which.max(eligible$Date), , drop = FALSE]
  age_days <- as.integer(as_of_date - latest$Date)
  if (age_days > max_age_days) {
    stop(sprintf(
      "Fed data are stale: %s is %d days before %s (limit: %d days).",
      latest$Date, age_days, as_of_date, max_age_days
    ), call. = FALSE)
  }
  yield_percent <- as.numeric(unlist(latest[yield_columns],
                                     use.names = FALSE))
  if (anyNA(yield_percent) || any(!is.finite(yield_percent))) {
    stop("The latest eligible curve has missing or non-finite yields.",
         call. = FALSE)
  }

  # SVENY values are percentages with continuous compounding.
  # Negative yields are valid inputs and are not clipped or deleted.
  zero_rate <- yield_percent / 100
  discount_factor <- exp(-zero_rate * maturity_years)
  if (any(!is.finite(discount_factor) | discount_factor <= 0)) {
    stop("The supplied yields produce invalid discount factors.",
         call. = FALSE)
  }
  data.frame(
    observation_date = rep(latest$Date, length(maturity_years)),
    maturity_years = maturity_years,
    zero_yield_percent = yield_percent,
    zero_rate_continuous = zero_rate,
    discount_factor = discount_factor
  )
}

#' Download, validate, and archive the current Fed GSW data vintage.
#' @param project_dir Existing project directory used for output paths.
#' @param as_of_date Analysis cutoff, normally Sys.Date().
#' @param max_age_days Maximum source age, allowing for weekly publication.
#' @param maturity_years Annual maturities to include, from 1 to 30.
#' @param source_url HTTPS address of the Fed CSV.
#' @return A list containing curve, metadata, raw_path, and snapshot_dir.
#' @details Each successful run creates a new processed snapshot. Raw files
#'   are deduplicated by their full MD5 content fingerprint (not a security
#'   signature). Failed requests never reuse cached data silently.
#'   A historical cutoff still uses the downloaded, possibly revised vintage;
#'   this is not a point-in-time historical data service.
download_fed_yield_curve <- function(
    project_dir = ".", as_of_date = Sys.Date(), max_age_days = 14L,
    maturity_years = 1:30,
    source_url = paste0("https://www.federalreserve.gov/data/",
                        "yield-curve-tables/feds200628.csv")) {
  maturity_years <- validate_fed_maturities(maturity_years)
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      is.na(project_dir) || !dir.exists(project_dir)) {
    stop("project_dir must be an existing directory.", call. = FALSE)
  }
  if (!is.character(source_url) || length(source_url) != 1L ||
      is.na(source_url) || !grepl("^https://", source_url)) {
    stop("source_url must be a single HTTPS URL.", call. = FALSE)
  }
  # Validate cutoff and freshness arguments before starting a network request.
  validate_fed_cutoff(as_of_date, max_age_days)

  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  raw_dir <- file.path(project_dir, "data", "raw", "fed_yield_curve")
  processed_dir <- file.path(project_dir, "data", "processed",
                             "fed_yield_curve")
  for (directory in c(raw_dir, processed_dir)) {
    if (!dir.exists(directory) &&
        !dir.create(directory, recursive = TRUE)) {
      stop(paste("Cannot create output directory:", directory),
           call. = FALSE)
    }
  }
  staged_raw <- tempfile("fed_download_", tmpdir = raw_dir, fileext = ".part")
  on.exit(unlink(staged_raw), add = TRUE)

  request <- httr2::request(source_url) |>
    httr2::req_user_agent("credit_metrics/0.1 (+portfolio research)") |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3, max_seconds = 120,
                     retry_on_failure = TRUE,
                     is_transient = function(response) {
                       httr2::resp_status(response) %in%
                         c(429L, 500L, 502L, 503L, 504L)
                     })
  response <- tryCatch(
    httr2::req_perform(request, path = staged_raw),
    error = function(error) {
      stop(paste("Fed download failed:", conditionMessage(error)),
           call. = FALSE)
    }
  )
  downloaded_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  history <- read_fed_yield_history(staged_raw, maturity_years)
  curve <- select_fed_yield_curve(history, as_of_date, max_age_days)
  fingerprint <- unname(tools::md5sum(staged_raw))
  if (is.na(fingerprint)) {
    stop("Could not fingerprint the downloaded source file.", call. = FALSE)
  }

  raw_name <- paste0("feds200628_", fingerprint, ".csv")
  raw_path <- file.path(raw_dir, raw_name)
  if (file.exists(raw_path)) {
    if (!identical(unname(tools::md5sum(raw_path)), fingerprint)) {
      stop("An existing raw snapshot has a conflicting fingerprint.",
           call. = FALSE)
    }
  } else if (!file.rename(staged_raw, raw_path)) {
    stop("Could not archive the validated source file.", call. = FALSE)
  }

  snapshot_dir <- tempfile(
    paste0("run_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_"),
    tmpdir = processed_dir
  )
  if (!dir.create(snapshot_dir)) {
    stop("Could not create the processed snapshot directory.", call. = FALSE)
  }
  completed <- FALSE
  on.exit(if (!completed) unlink(snapshot_dir, recursive = TRUE), add = TRUE)

  metadata <- data.frame(
    provider = "Federal Reserve Board",
    dataset = "GSW nominal Treasury zero-coupon yield curve",
    source_url = source_url,
    downloaded_at_utc = downloaded_at,
    requested_as_of_date = as_of_date,
    observation_date = curve$observation_date[1],
    age_calendar_days = as.integer(as_of_date - curve$observation_date[1]),
    max_age_calendar_days = max_age_days,
    publication_cadence = "Usually weekly; daily observations",
    compounding = "continuous",
    input_yield_units = "percent per annum",
    output_rate_units = "decimal per annum",
    history_rows = nrow(history),
    maturity_count = nrow(curve),
    raw_md5 = fingerprint,
    raw_file = file.path("data", "raw", "fed_yield_curve", raw_name),
    http_status = httr2::resp_status(response)
  )
  readr::write_csv(curve, file.path(snapshot_dir, "curve.csv"))
  readr::write_csv(metadata, file.path(snapshot_dir, "metadata.csv"))
  completed <- TRUE
  message(sprintf("Fed curve: %s; age: %d calendar days; maturities: %d.",
                  metadata$observation_date, metadata$age_calendar_days,
                  nrow(curve)))
  list(curve = curve, metadata = metadata, raw_path = raw_path,
       snapshot_dir = snapshot_dir)
}
