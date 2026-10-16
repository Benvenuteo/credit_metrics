# Purpose: read rating-index OAS observations from FRED for a valuation proxy.
# OAS / 100 is used as an additive continuous-spread approximation, not as
# an exact conversion of an index OAS into a zero-coupon credit term structure.

#' Map model rating buckets to documented ICE BofA OAS series on FRED.
rating_spread_series <- function() {
  c(AAA = "BAMLC0A1CAAA", AA = "BAMLC0A2CAA", A = "BAMLC0A3CA",
    BBB = "BAMLC0A4CBBB", BB = "BAMLH0A1HYBB", B = "BAMLH0A2HYB",
    `CCC/C` = "BAMLH0A3HYC")
}

#' Read the expected seven series without guessing units or filling gaps.
#' @return Typed FRED percent history, retaining historical NAs.
read_rating_spread_history <- function(path) {
  series <- unname(rating_spread_series())
  parsers <- c(list(observation_date = readr::col_date()),
               setNames(rep(list(readr::col_double()), length(series)), series))
  history <- suppressWarnings(readr::read_csv(
    path, col_types = do.call(readr::cols_only, parsers),
    na = c("", ".", "NA"), name_repair = "check_unique",
    show_col_types = FALSE, progress = FALSE, lazy = FALSE
  ))
  if (!all(c("observation_date", series) %in% names(history)) ||
      !nrow(history) || nrow(readr::problems(history)) ||
      anyNA(history$observation_date) ||
      anyDuplicated(history$observation_date)) {
    stop("FRED OAS history has invalid/missing data or duplicate dates.",
         call. = FALSE)
  }
  values <- as.matrix(history[, series])
  if (any(is.infinite(values) | is.nan(values))) {
    stop("FRED OAS history contains non-finite observations.", call. = FALSE)
  }
  as.data.frame(history[order(history$observation_date), ])
}

#' Select the latest observed OAS row, rejecting a partially missing latest row.
#' @return Seven rating spreads on one date, with both source and model units.
select_rating_spreads <- function(history, as_of_date, max_age_days = 7L) {
  validate_issuer_date(as_of_date, "as_of_date")
  if (!is.numeric(max_age_days) || length(max_age_days) != 1L ||
      is.na(max_age_days) || !is.finite(max_age_days) || max_age_days < 0 ||
      max_age_days != floor(max_age_days)) {
    stop("max_age_days must be a non-negative integer.", call. = FALSE)
  }
  series <- rating_spread_series()
  if (!is.data.frame(history) ||
      !all(c("observation_date", unname(series)) %in% names(history)) ||
      !inherits(history$observation_date, "Date") ||
      anyNA(history$observation_date) ||
      anyDuplicated(history$observation_date) ||
      !all(vapply(history[unname(series)], is.numeric, logical(1)))) {
    stop("Supply typed OAS history with unique dates and all expected series.",
         call. = FALSE)
  }
  values <- as.matrix(history[unname(series)])
  if (any(is.infinite(values) | is.nan(values))) {
    stop("OAS observations must be finite when present.", call. = FALSE)
  }
  # An all-missing calendar row is not a published market observation.
  eligible <- which(history$observation_date <= as_of_date &
                      rowSums(!is.na(values)) > 0L)
  if (!length(eligible)) stop("No eligible OAS observations.", call. = FALSE)
  row <- eligible[which.max(history$observation_date[eligible])]
  date <- history$observation_date[row]
  if (as.integer(as_of_date - date) > max_age_days) {
    stop("The latest OAS observation is stale.", call. = FALSE)
  }
  if (anyNA(values[row, ])) {
    stop("The latest OAS observation is missing a rating series.",
         call. = FALSE)
  }
  data.frame(
    rating_bucket = names(series), series_id = unname(series),
    observation_date = date, index_oas_percent = as.numeric(values[row, ]),
    spread_decimal_proxy = as.numeric(values[row, ]) / 100
  )
}

#' Choose a common Treasury/OAS observation date without filling either source.
#' @return Same-date curve and spreads plus the chosen market date.
#' @details A partial row on the latest shared observed date raises an error.
#'   Latest-feed freshness is checked separately by the orchestration layer.
align_credit_market_inputs <- function(fed_history, spread_history,
                                       as_of_date, max_age_days = 14L) {
  validate_issuer_date(as_of_date, "as_of_date")
  series <- unname(rating_spread_series())
  observed <- rowSums(!is.na(as.matrix(spread_history[series]))) > 0L
  shared <- fed_history$Date[
    fed_history$Date %in% spread_history$observation_date[observed] &
      fed_history$Date <= as_of_date
  ]
  if (!length(shared)) {
    stop("No shared Treasury/OAS market observation date.", call. = FALSE)
  }
  date <- max(shared)
  # Validate the chosen date with the same cutoff rules as the Fed importer.
  validate_fed_cutoff(as_of_date, max_age_days)
  if (as.integer(as_of_date - date) > max_age_days) {
    stop("The shared Treasury/OAS observation date is stale.", call. = FALSE)
  }
  list(
    market_date = date,
    curve = select_fed_yield_curve(fed_history, date, max_age_days = 0L),
    spreads = select_rating_spreads(spread_history, date, max_age_days = 0L)
  )
}
