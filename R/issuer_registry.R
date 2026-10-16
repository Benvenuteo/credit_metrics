# Purpose: maintain an auditable, manually reviewed issuer register.
# Ratings are inputs supported by dated sources, not an automated live feed.

#' Map full S&P rating notches to the broad migration categories.
#' @param ratings Character vector of long-term S&P ratings.
#' @return Character vector; unrated or unknown values raise an error.
sp_rating_bucket <- function(ratings) {
  allowed <- c("AAA", "AA+", "AA", "AA-", "A+", "A", "A-",
               "BBB+", "BBB", "BBB-", "BB+", "BB", "BB-",
               "B+", "B", "B-", "CCC+", "CCC", "CCC-", "CC", "C",
               "SD", "D")
  if (!is.character(ratings) || !length(ratings) || anyNA(ratings) ||
      any(!ratings %in% allowed)) {
    stop("Supply recognized long-term S&P ratings; NR is not a risk state.",
         call. = FALSE)
  }
  buckets <- sub("[+-]$", "", ratings)
  buckets[buckets %in% c("CCC", "CC", "C")] <- "CCC/C"
  buckets[buckets == "SD"] <- "D"
  buckets
}

#' Validate one finite calendar date without converting strings silently.
#' @param value Date to validate.
#' @param label Name included in any error message.
#' @return NULL invisibly.
validate_issuer_date <- function(value, label) {
  if (!inherits(value, "Date") || length(value) != 1L || is.na(value) ||
      !is.finite(as.numeric(value))) {
    stop(paste(label, "must be a single non-missing Date."), call. = FALSE)
  }
  invisible(NULL)
}

#' Read and validate the source-controlled US issuer register.
#' @param path Registry CSV, normally config/issuers.csv.
#' @param review_as_of_date Date on which the manual review is assessed.
#' @param max_review_age_days Maximum calendar-day age of a manual review.
#' @return A typed data frame in the configured portfolio order.
#' @details A recent review date is a governance check, not proof that no
#'   unpublished or inaccessible rating action occurred. Source dates and
#'   review dates remain separate. Never refresh the date without a review.
read_issuer_registry <- function(path, review_as_of_date = Sys.Date(),
                                 max_review_age_days = 30L) {
  validate_issuer_date(review_as_of_date, "review_as_of_date")
  if (!is.numeric(max_review_age_days) || length(max_review_age_days) != 1L ||
      is.na(max_review_age_days) || !is.finite(max_review_age_days) ||
      max_review_age_days < 0 ||
      max_review_age_days != floor(max_review_age_days)) {
    stop("max_review_age_days must be a non-negative integer.", call. = FALSE)
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) ||
      !file.exists(path) || dir.exists(path)) {
    stop("path must point to an existing issuer registry CSV.", call. = FALSE)
  }
  registry <- suppressWarnings(readr::read_csv(
    path, col_types = readr::cols(
      .default = readr::col_character(),
      notional_usd_million = readr::col_double(),
      maturity_years = readr::col_double(),
      rating_source_date = readr::col_date(),
      rating_reviewed_on = readr::col_date()
    ), name_repair = "check_unique", show_col_types = FALSE,
    progress = FALSE, lazy = FALSE
  ))
  required <- c("issuer_id", "issuer_name", "ticker", "exchange", "currency",
                "notional_usd_million", "maturity_years", "rating_agency",
                "rating_type", "rating_notch", "rating_bucket", "rating_outlook",
                "rating_source_date", "rating_reviewed_on", "rating_source_url",
                "ticker_source_url", "rating_review_note")
  if (!all(required %in% names(registry)) || !nrow(registry)) {
    stop("The issuer registry is empty or missing required columns.",
         call. = FALSE)
  }
  if (nrow(readr::problems(registry)) || anyNA(registry[, required])) {
    stop("The issuer registry contains missing or malformed values.",
         call. = FALSE)
  }
  text_columns <- setdiff(required, c("notional_usd_million", "maturity_years",
                                     "rating_source_date", "rating_reviewed_on"))
  if (any(vapply(registry[, text_columns], function(x) {
    any(!nzchar(trimws(x)) | x != trimws(x))
  }, logical(1)))) {
    stop("Registry text fields must be non-empty and trimmed.", call. = FALSE)
  }
  if (anyDuplicated(registry$issuer_id) || anyDuplicated(registry$ticker) ||
      any(!grepl("^[A-Z][A-Z0-9_]*$", registry$issuer_id)) ||
      any(!grepl("^[A-Z][A-Z0-9.-]*$", registry$ticker))) {
    stop("Issuer identifiers and tickers must be valid and unique.",
         call. = FALSE)
  }
  if (any(registry$currency != "USD") ||
      any(!registry$exchange %in% c("NASDAQ", "NYSE"))) {
    stop("This importer supports USD listings on NASDAQ or NYSE only.",
         call. = FALSE)
  }
  amounts <- unlist(registry[c("notional_usd_million", "maturity_years")])
  if (any(!is.finite(amounts) | amounts <= 0)) {
    stop("Portfolio notionals and maturities must be finite and positive.",
         call. = FALSE)
  }
  if (any(registry$rating_agency != "S&P Global Ratings") ||
      any(registry$rating_type != "issuer_long_term")) {
    stop("Use S&P long-term issuer ratings, not issue ratings or other agencies.",
         call. = FALSE)
  }
  if (any(sp_rating_bucket(registry$rating_notch) != registry$rating_bucket)) {
    stop("The rating bucket does not match the full S&P rating notch.",
         call. = FALSE)
  }
  if (any(registry$rating_source_date > registry$rating_reviewed_on) ||
      any(registry$rating_reviewed_on > review_as_of_date)) {
    stop("Rating source and review dates must not lie in the future.",
         call. = FALSE)
  }
  review_age <- as.integer(review_as_of_date - registry$rating_reviewed_on)
  if (any(review_age > max_review_age_days)) {
    stop(paste0("Issuer rating review is stale for: ",
                paste(registry$issuer_id[review_age > max_review_age_days],
                      collapse = ", "), ". Review sources and record the result."),
         call. = FALSE)
  }
  if (any(!grepl("^https://www\\.spglobal\\.com/ratings/",
                 registry$rating_source_url)) ||
      any(!grepl("^https://", registry$ticker_source_url))) {
    stop("Registry source links must be HTTPS primary-source URLs.",
         call. = FALSE)
  }
  as.data.frame(registry[, required])
}
