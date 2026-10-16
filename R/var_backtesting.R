# Purpose: evaluate dated one-year VaR exceptions with exact binomial tails.
# Kupiec tests coverage frequency; neither test establishes independence.

#' Test an exception count under a fixed independent Bernoulli null.
#' @param confidence_level VaR confidence alpha; null exception rate is 1-alpha.
#' @param tail_significance Rejection level in each inclusive binomial tail.
#' @param kupiec_significance Separate size of the asymptotic Kupiec LR test.
#' @details Two 5% tails have total size at most 10%, not 5%. For at most 5%
#'   central size, use 2.5% per tail. Equality at VaR is not an exception.
test_var_exception_count <- function(
    n_observations, n_exceptions, confidence_level,
    tail_significance = 0.05, kupiec_significance = 0.05) {
  check_simulation_integer(n_observations, "n_observations", 1L)
  check_simulation_integer(n_exceptions, "n_exceptions", 0L, n_observations)
  check_credit_risk_levels(confidence_level)
  if (length(confidence_level) != 1L ||
      !is.numeric(tail_significance) || length(tail_significance) != 1L ||
      !is.finite(tail_significance) || tail_significance <= 0 ||
      tail_significance >= 0.5 || !is.numeric(kupiec_significance) ||
      length(kupiec_significance) != 1L ||
      !is.finite(kupiec_significance) || kupiec_significance <= 0 ||
      kupiec_significance >= 1) {
    stop("Use one VaR confidence and valid binomial/Kupiec significance.",
         call. = FALSE)
  }
  n <- n_observations
  m <- n_exceptions
  probability <- 1 - confidence_level
  lower <- stats::pbinom(m, n, probability)
  # P(M >= m) = P(M > m-1); using m here would omit the observed atom.
  upper <- stats::pbinom(m - 1L, n, probability, lower.tail = FALSE)
  fitted_probability <- m / n
  log_null <- stats::dbinom(m, n, probability, log = TRUE)
  log_fitted <- stats::dbinom(m, n, fitted_probability, log = TRUE)
  lr <- max(0, 2 * (log_fitted - log_null))
  kupiec_p <- stats::pchisq(lr, df = 1L, lower.tail = FALSE)
  interval <- stats::binom.test(m, n, conf.level =
                                 1 - 2 * tail_significance)$conf.int
  data.frame(
    confidence_level = confidence_level, n_observations = n,
    n_exceptions = m, expected_exceptions = n * probability,
    observed_exception_rate = fitted_probability,
    null_exception_probability = probability,
    lower_inclusive_probability = lower, upper_inclusive_probability = upper,
    tail_significance = tail_significance,
    central_size_upper_bound = 2 * tail_significance,
    reject_too_few = lower <= tail_significance,
    reject_too_many = upper <= tail_significance,
    central_binomial_not_rejected =
      lower > tail_significance && upper > tail_significance,
    exception_rate_ci_lower = interval[1L],
    exception_rate_ci_upper = interval[2L],
    kupiec_lr_uc = lr, kupiec_df = 1L, kupiec_p_value = kupiec_p,
    kupiec_significance = kupiec_significance,
    kupiec_not_rejected = kupiec_p > kupiec_significance
  )
}

#' Validate explicit forecast/outcome pairs; never construct observed outcomes.
#' @param path CSV with provenance, annual periods, VaR and realized losses.
#' @param evaluation_date Latest permitted realized horizon end date.
#' @return Dated exceptions and both requested central-binomial conventions.
#' @details Annual contract dates span 365/366 days. Overlapping periods are
#'   rejected separately per confidence level. This is necessary, but does not
#'   establish iid exceptions, correct provenance or historical vintages.
read_credit_var_backtest <- function(path, evaluation_date) {
  validate_issuer_date(evaluation_date, "evaluation_date")
  rows <- suppressWarnings(readr::read_csv(
    path, col_types = readr::cols(
      .default = readr::col_character(), forecast_date = readr::col_date(),
      horizon_end_date = readr::col_date(),
      estimation_end_date = readr::col_date(),
      estimation_window_size = readr::col_double(),
      var_usd_million = readr::col_double(),
      realized_loss_usd_million = readr::col_double(),
      confidence_level = readr::col_double()
    ), name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  ))
  fields <- c("portfolio_id", "forecast_date", "horizon_end_date",
                "estimation_end_date", "estimation_window_size",
                "var_usd_million", "realized_loss_usd_million",
                "confidence_level", "forecast_benchmark", "realized_benchmark",
                "outcome_type", "loss_source")
  if (!all(fields %in% names(rows)) || !nrow(rows) ||
      nrow(readr::problems(rows)) || anyNA(rows[fields])) {
    stop("Supply complete typed VaR forecasts and realized outcomes.",
         call. = FALSE)
  }
  numeric_fields <- c("estimation_window_size", "var_usd_million",
                        "realized_loss_usd_million", "confidence_level")
  if (any(!is.finite(as.matrix(rows[numeric_fields]))) ||
      any(rows$estimation_window_size < 2 | rows$estimation_window_size !=
            floor(rows$estimation_window_size)) ||
      any(rows$confidence_level <= 0 | rows$confidence_level >= 1) ||
      length(unique(rows$portfolio_id)) != 1L ||
      !nzchar(trimws(rows$portfolio_id[1L])) ||
      any(!nzchar(trimws(rows$loss_source))) ||
      length(unique(rows$outcome_type)) != 1L ||
      any(!rows$outcome_type %in% c("observed_portfolio_loss",
                                    "historical_revaluation_proxy",
                                    "synthetic_example"))) {
    stop("Use finite values, one portfolio/outcome type and explicit sources.",
         call. = FALSE)
  }
  duration <- as.integer(rows$horizon_end_date - rows$forecast_date)
  if (any(!duration %in% c(365L, 366L)) ||
      any(rows$estimation_end_date > rows$forecast_date) ||
      any(rows$horizon_end_date > evaluation_date) ||
      any(rows$forecast_benchmark != "no_migration_horizon") ||
      any(rows$realized_benchmark != rows$forecast_benchmark)) {
    stop(paste0("Require completed annual horizons, no future estimation ",
                  "data and matching no_migration_horizon benchmarks."),
         call. = FALSE)
  }
  rows <- as.data.frame(rows[order(rows$confidence_level, rows$forecast_date),
                              fields])
  levels <- sort(unique(rows$confidence_level))
  summaries <- lapply(levels, function(alpha) {
    one <- rows[rows$confidence_level == alpha, , drop = FALSE]
    if (anyDuplicated(one$forecast_date) ||
        (nrow(one) > 1L && any(tail(one$forecast_date, -1L) <
                                head(one$horizon_end_date, -1L)))) {
      stop("Annual backtest periods must not overlap at a given VaR level.",
           call. = FALSE)
    }
    m <- sum(one$realized_loss_usd_million > one$var_usd_million)
    tests <- do.call(rbind, lapply(c(0.05, 0.025), function(tail_size) {
      test_var_exception_count(nrow(one), m, alpha, tail_size)
    }))
    tests$n_equal_to_var <-
      sum(one$realized_loss_usd_million == one$var_usd_million)
    tests$outcome_type <- one$outcome_type[1L]
    tests
  })
  rows$exception <- rows$realized_loss_usd_million > rows$var_usd_million
  rows$equal_to_var <- rows$realized_loss_usd_million == rows$var_usd_million
  list(observations = rows, summary = do.call(rbind, summaries),
       outcome_type = rows$outcome_type[1L],
       file_md5 = unname(tools::md5sum(path)))
}
