# Purpose: collect daily equity prices and estimate an issuer correlation proxy.
# Source exports are preserved locally; no missing prices are interpolated.

#' Exclude the current New York calendar day, even after the market closes.
#' @param now Current instant, supplied explicitly in deterministic tests.
#' @return Yesterday in America/New_York. Weekends are handled by the source.
default_equity_cutoff <- function(now = Sys.time()) {
  if (!inherits(now, "POSIXt") || length(now) != 1L || is.na(now) ||
      !is.finite(as.numeric(now))) {
    stop("now must be a single finite POSIXt instant.", call. = FALSE)
  }
  as.Date(format(now, "%Y-%m-%d", tz = "America/New_York")) - 1L
}

#' Validate the requested price window and sample-quality policies.
#' @return NULL invisibly.
validate_price_controls <- function(from_date, as_of_date, max_age_days,
                                    min_observations, min_coverage,
                                    extreme_return_threshold) {
  validate_issuer_date(from_date, "from_date")
  validate_issuer_date(as_of_date, "as_of_date")
  if (from_date >= as_of_date) {
    stop("from_date must precede as_of_date.", call. = FALSE)
  }
  for (control in c("max_age_days", "min_observations")) {
    value <- get(control)
    minimum <- if (control == "min_observations") 3L else 0L
    if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
        !is.finite(value) || value != floor(value) || value < minimum) {
      stop(paste(control, "must be an integer >=", minimum), call. = FALSE)
    }
  }
  if (!is.numeric(min_coverage) || length(min_coverage) != 1L ||
      is.na(min_coverage) || !is.finite(min_coverage) ||
      min_coverage <= 0 || min_coverage > 1) {
    stop("min_coverage must be greater than zero and at most one.",
         call. = FALSE)
  }
  if (!is.numeric(extreme_return_threshold) ||
      length(extreme_return_threshold) != 1L ||
      is.na(extreme_return_threshold) || !is.finite(extreme_return_threshold) ||
      extreme_return_threshold <= 0) {
    stop("extreme_return_threshold must be finite and positive.", call. = FALSE)
  }
  invisible(NULL)
}

#' Download one daily OHLCV/Adjusted export using quantmod's Yahoo adapter.
#' @return The xts object returned by quantmod, without a second adjustment.
fetch_yahoo_prices <- function(ticker, from_date, as_of_date) {
  tryCatch(
    quantmod::getSymbols(
      Symbols = ticker, src = "yahoo", from = from_date, to = as_of_date + 1L,
      auto.assign = FALSE, symbol.lookup = FALSE, adjust = FALSE,
      periodicity = "daily", warnings = FALSE,
      curl.options = list(timeout = 45, connecttimeout = 15)
    ),
    error = function(error) {
      stop(paste0("Yahoo price download failed for ", ticker, ": ",
                  conditionMessage(error), ". No cached prices were substituted."),
           call. = FALSE)
    }
  )
}

#' Convert a saved quantmod source export without guessing column positions.
#' @return A data frame of source prices, including unadjusted and adjusted close.
parse_yahoo_prices <- function(source_export, issuer_id, ticker) {
  suffixes <- c("Open", "High", "Low", "Close", "Volume", "Adjusted")
  expected <- paste(ticker, suffixes, sep = ".")
  if (!inherits(source_export, "xts") || !NROW(source_export) ||
      !all(expected %in% colnames(source_export))) {
    stop(paste("Invalid or incomplete quantmod export for", ticker),
         call. = FALSE)
  }
  values <- as.data.frame(as.matrix(source_export[, expected]))
  names(values) <- tolower(suffixes)
  data.frame(issuer_id = issuer_id, ticker = ticker,
             date = as.Date(zoo::index(source_export)), values, row.names = NULL)
}

#' Check a correlation matrix without silently repairing it.
#' @return The minimum eigenvalue, invisibly. Singular PSD matrices are valid.
validate_issuer_correlation <- function(correlation, tolerance = 1e-8) {
  if (!is.matrix(correlation) || !is.numeric(correlation) ||
      nrow(correlation) < 2L || nrow(correlation) != ncol(correlation) ||
      any(!is.finite(correlation)) ||
      !isTRUE(all.equal(correlation, t(correlation), tolerance = tolerance)) ||
      any(abs(diag(correlation) - 1) > tolerance) ||
      any(abs(correlation) > 1 + tolerance)) {
    stop("The correlation matrix is not finite, symmetric and unit-diagonal.",
         call. = FALSE)
  }
  minimum <- min(eigen(correlation, symmetric = TRUE, only.values = TRUE)$values)
  if (minimum < -tolerance) {
    stop("The correlation matrix is not positive semidefinite.", call. = FALSE)
  }
  invisible(minimum)
}

#' Validate prices and build a common sample of matching return intervals.
#' @param prices Long data frame with issuer_id, ticker, date and OHLCV/Adjusted.
#' @param registry Validated issuer register, in the required matrix order.
#' @param from_date First eligible price date, inclusive.
#' @param as_of_date Last eligible completed-day price date, inclusive.
#' @param max_age_days Maximum calendar age of latest prices and common returns.
#' @param min_observations Minimum number of common returns, normally 500.
#' @param min_coverage Minimum common fraction of candidate return end dates.
#' @param extreme_return_threshold Flag absolute log returns above this level.
#' @return Validated prices, returns, correlation, quality and exclusion audit.
#' @details Returns are computed within each original price series BEFORE
#'   alignment. Both the start and end dates must agree across issuers. Missing
#'   observations are never forward-filled, dropped before differencing, or
#'   winsorized. The correlation is an equity-return proxy, not an observed
#'   asset/default correlation. All pairs use the same complete sample.
prepare_issuer_prices <- function(
    prices, registry, from_date, as_of_date, max_age_days = 7L,
    min_observations = 500L, min_coverage = 0.95,
    extreme_return_threshold = 0.35) {
  validate_price_controls(from_date, as_of_date, max_age_days,
                          min_observations, min_coverage,
                          extreme_return_threshold)
  ids <- registry$issuer_id
  if (!is.data.frame(registry) || length(ids) < 2L || anyNA(ids) ||
      anyDuplicated(ids) || anyDuplicated(registry$ticker)) {
    stop("Supply a validated registry containing at least two unique issuers.",
         call. = FALSE)
  }
  numeric_columns <- c("open", "high", "low", "close", "volume", "adjusted")
  required <- c("issuer_id", "ticker", "date", numeric_columns)
  if (!is.data.frame(prices) || !all(required %in% names(prices)) ||
      !inherits(prices$date, "Date") || anyNA(prices$date) ||
      any(!is.finite(as.numeric(prices$date))) ||
      anyNA(prices$issuer_id) || anyNA(prices$ticker) ||
      !setequal(unique(prices$issuer_id), ids)) {
    stop("Prices must contain dated observations for every configured issuer.",
         call. = FALSE)
  }
  if (any(prices$ticker != registry$ticker[match(prices$issuer_id, ids)])) {
    stop("A price ticker does not match its configured issuer.", call. = FALSE)
  }
  if (!all(vapply(prices[numeric_columns], is.numeric, logical(1)))) {
    stop("Source price and volume columns must be numeric.", call. = FALSE)
  }
  price_values <- as.matrix(prices[setdiff(numeric_columns, "volume")])
  if (any(is.infinite(price_values) | is.nan(price_values)) ||
      any(price_values <= 0, na.rm = TRUE) ||
      any(is.infinite(prices$volume) | is.nan(prices$volume)) ||
      any(prices$volume < 0, na.rm = TRUE)) {
    stop("Non-missing prices must be finite and positive; volume cannot be negative.",
         call. = FALSE)
  }
  if (anyDuplicated(prices[c("issuer_id", "date")])) {
    stop("Duplicate issuer/date observations are not permitted.", call. = FALSE)
  }
  prices <- prices[prices$date >= from_date & prices$date <= as_of_date,
                   required, drop = FALSE]
  by_issuer <- vector("list", length(ids))
  quality <- vector("list", length(ids))
  for (i in seq_along(ids)) {
    one <- prices[prices$issuer_id == ids[i], , drop = FALSE]
    one <- one[order(one$date), , drop = FALSE]
    if (nrow(one) < 2L) {
      stop(paste("Not enough eligible prices for", ids[i]), call. = FALSE)
    }
    latest <- one[nrow(one), , drop = FALSE]
    if (is.na(latest$adjusted) || is.na(latest$close)) {
      stop(paste("The latest price is missing for", ids[i]), call. = FALSE)
    }
    age <- as.integer(as_of_date - latest$date)
    if (age > max_age_days) {
      stop(paste("The latest price is stale for", ids[i]), call. = FALSE)
    }
    one$previous_date <- c(as.Date(NA), head(one$date, -1L))
    one$log_return <- c(NA_real_, diff(log(one$adjusted)))
    one$extreme_return <- !is.na(one$log_return) &
      abs(one$log_return) > extreme_return_threshold
    by_issuer[[i]] <- one
    quality[[i]] <- data.frame(
      issuer_id = ids[i], ticker = registry$ticker[i],
      first_price_date = min(one$date), latest_price_date = latest$date,
      age_calendar_days = age, price_rows = nrow(one),
      missing_adjusted = sum(is.na(one$adjusted)),
      finite_returns = sum(is.finite(one$log_return)),
      extreme_return_count = sum(one$extreme_return)
    )
  }
  prices <- do.call(rbind, by_issuer)
  rownames(prices) <- NULL
  quality <- do.call(rbind, quality)
  candidate_dates <- sort(unique(prices$date[!is.na(prices$previous_date)]))
  returns <- matrix(NA_real_, nrow = length(candidate_dates), ncol = length(ids),
                    dimnames = list(NULL, ids))
  previous_dates <- returns
  for (i in seq_along(ids)) {
    one <- by_issuer[[i]]
    one <- one[!is.na(one$previous_date), , drop = FALSE]
    index <- match(one$date, candidate_dates)
    returns[index, i] <- one$log_return
    previous_dates[index, i] <- as.numeric(one$previous_date)
  }
  complete <- rowSums(is.finite(returns)) == length(ids)
  matching_interval <- apply(previous_dates, 1L, function(x) {
    all(is.finite(x)) && length(unique(x)) == 1L
  })
  retained <- complete & matching_interval
  audit <- data.frame(
    date = candidate_dates,
    missing_returns = rowSums(!is.finite(returns)),
    matching_start_dates = matching_interval, retained = retained
  )
  count <- sum(retained)
  coverage <- mean(retained)
  if (count < min_observations) {
    stop(sprintf("Only %d common return intervals; at least %d are required.",
                 count, min_observations), call. = FALSE)
  }
  if (coverage < min_coverage) {
    stop(sprintf("Common sample coverage is %.2f%%; at least %.2f%% is required.",
                 100 * coverage, 100 * min_coverage), call. = FALSE)
  }
  if (as.integer(as_of_date - max(candidate_dates[retained])) > max_age_days) {
    stop("The latest common return interval is stale.", call. = FALSE)
  }
  common <- returns[retained, , drop = FALSE]
  deviations <- apply(common, 2L, stats::sd)
  if (any(!is.finite(deviations) | deviations <= 0)) {
    stop("Cannot estimate correlation for a constant return series.",
         call. = FALSE)
  }
  correlation <- stats::cor(common, method = "pearson")
  min_eigenvalue <- validate_issuer_correlation(correlation)
  common_returns <- data.frame(
    date = candidate_dates[retained],
    previous_date = as.Date(previous_dates[retained, 1L], origin = "1970-01-01"),
    common, check.names = FALSE
  )
  quality$common_returns <- count
  quality$common_coverage <- coverage
  list(prices = prices, returns = common_returns, correlation = correlation,
       quality = quality, sample_audit = audit,
       outliers = prices[prices$extreme_return, , drop = FALSE],
       min_eigenvalue = min_eigenvalue)
}

#' Download and archive a complete issuer-price analysis run.
#' @param project_dir Existing project root.
#' @param as_of_date Inclusive completed-day cutoff; default excludes today in NY.
#' @param from_date Inclusive start, default three calendar years before cutoff.
#' @param review_as_of_date Date for assessing the manual rating review.
#' @param max_review_age_days Maximum age of that review, default 30 days.
#' @param price_fetcher Download function; injectable for offline integration tests.
#' @return The analysis plus registry, metadata, raw_path and snapshot_dir.
#' @details source_exports.rds preserves quantmod's returned objects, not the
#'   original HTTP response. Every run has a new directory. Failure never
#'   silently substitutes Close for Adjusted, cached data, or a different source.
download_issuer_prices <- function(
    project_dir = ".", as_of_date = default_equity_cutoff(),
    from_date = seq(as_of_date, by = "-3 years", length.out = 2L)[2L],
    max_age_days = 7L, min_observations = 500L, min_coverage = 0.95,
    extreme_return_threshold = 0.35, review_as_of_date = Sys.Date(),
    max_review_age_days = 30L, price_fetcher = fetch_yahoo_prices) {
  validate_price_controls(from_date, as_of_date, max_age_days,
                          min_observations, min_coverage,
                          extreme_return_threshold)
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      is.na(project_dir) || !dir.exists(project_dir)) {
    stop("project_dir must be an existing directory.", call. = FALSE)
  }
  if (!is.function(price_fetcher)) {
    stop("price_fetcher must be a function.", call. = FALSE)
  }
  if (as_of_date > default_equity_cutoff()) {
    stop("as_of_date must exclude the current New York calendar day.",
         call. = FALSE)
  }
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  registry_path <- file.path(project_dir, "config", "issuers.csv")
  registry <- read_issuer_registry(registry_path, review_as_of_date,
                                    max_review_age_days)
  registry_fingerprint <- unname(tools::md5sum(registry_path))
  if (any(registry$rating_source_date > as_of_date)) {
    stop("This current rating register cannot support that historical cutoff.",
         call. = FALSE)
  }
  exports <- vector("list", nrow(registry))
  names(exports) <- registry$issuer_id
  frames <- vector("list", nrow(registry))
  for (i in seq_len(nrow(registry))) {
    message("Downloading daily prices: ", registry$ticker[i])
    exports[[i]] <- price_fetcher(registry$ticker[i], from_date, as_of_date)
    frames[[i]] <- parse_yahoo_prices(exports[[i]], registry$issuer_id[i],
                                      registry$ticker[i])
  }
  downloaded_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  analysis <- prepare_issuer_prices(
    do.call(rbind, frames), registry, from_date, as_of_date, max_age_days,
    min_observations, min_coverage, extreme_return_threshold
  )
  processed_root <- file.path(project_dir, "data", "processed", "issuer_prices")
  raw_root <- file.path(project_dir, "data", "raw", "issuer_prices")
  for (directory in c(processed_root, raw_root)) {
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE)) {
      stop(paste("Cannot create output directory:", directory), call. = FALSE)
    }
  }
  run_name <- basename(tempfile(paste0(
    "run_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_"
  )))
  raw_dir <- file.path(raw_root, run_name)
  snapshot_dir <- file.path(processed_root, run_name)
  completed <- FALSE
  created_directories <- character()
  on.exit(if (!completed) {
    unlink(created_directories, recursive = TRUE)
  }, add = TRUE)
  for (directory in c(raw_dir, snapshot_dir)) {
    if (!dir.create(directory)) {
      stop("Cannot create immutable run directories.", call. = FALSE)
    }
    created_directories <- c(created_directories, directory)
  }
  raw_path <- file.path(raw_dir, "source_exports.rds")
  saveRDS(exports, raw_path, version = 3)
  # Keep the exact registry bytes as well as the parsed registry used below.
  if (!identical(unname(tools::md5sum(registry_path)), registry_fingerprint) ||
      !file.copy(registry_path, file.path(raw_dir, "issuers.csv"))) {
    stop("Cannot preserve the source registry.", call. = FALSE)
  }
  metadata <- data.frame(
    provider = "Yahoo Finance via quantmod",
    retrieval_method = "getSymbols(src='yahoo', adjust=FALSE, periodicity='daily')",
    downloaded_at_utc = downloaded_at,
    requested_from_date = from_date, requested_as_of_date = as_of_date,
    cutoff_policy = "Exclude current New York calendar day",
    return_definition = "log(Adjusted[t]/Adjusted[previous_source_row])",
    adjustment_policy = "Provider Adjusted; no second adjustment or Close fallback",
    correlation_method = "Pearson; complete common sample; identical intervals",
    correlation_role = "Equity-return proxy for issuer dependence",
    common_first_date = min(analysis$returns$date),
    common_last_date = max(analysis$returns$date),
    common_observations = nrow(analysis$returns),
    candidate_intervals = nrow(analysis$sample_audit),
    common_coverage = mean(analysis$sample_audit$retained),
    minimum_eigenvalue = analysis$min_eigenvalue,
    max_price_age_days = max_age_days, min_observations = min_observations,
    min_coverage = min_coverage, extreme_return_threshold = extreme_return_threshold,
    manual_rating_review_as_of = review_as_of_date,
    max_rating_review_age_days = max_review_age_days,
    registry_md5 = registry_fingerprint,
    source_exports_md5 = unname(tools::md5sum(raw_path)),
    source_exports_file = file.path("data", "raw", "issuer_prices", run_name,
                                    "source_exports.rds"),
    r_version = as.character(getRversion()),
    quantmod_version = as.character(utils::packageVersion("quantmod")),
    readr_version = as.character(utils::packageVersion("readr"))
  )
  sources <- data.frame(
    issuer_id = registry$issuer_id, ticker = registry$ticker,
    configured_currency = registry$currency, configured_exchange = registry$exchange,
    source_page = paste0("https://finance.yahoo.com/quote/", registry$ticker,
                         "/history/")
  )
  tables <- c(analysis[c("prices", "returns", "quality", "sample_audit", "outliers")],
              list(metadata = metadata, issuer_registry = registry, sources = sources,
                   correlation = data.frame(issuer_id = rownames(analysis$correlation),
                                              analysis$correlation, check.names = FALSE)))
  for (name in names(tables)) {
    readr::write_csv(tables[[name]], file.path(snapshot_dir, paste0(name, ".csv")))
  }
  completed <- TRUE
  message(sprintf("Common returns: %d; coverage: %.2f%%; latest date: %s.",
                  nrow(analysis$returns), 100 * metadata$common_coverage,
                  metadata$common_last_date))
  if (nrow(analysis$outliers)) {
    warning(sprintf("%d extreme source returns flagged in outliers.csv; none removed.",
                    nrow(analysis$outliers)), call. = FALSE)
  }
  c(analysis, list(registry = registry, metadata = metadata, raw_path = raw_path,
                   snapshot_dir = snapshot_dir))
}
