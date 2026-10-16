# Purpose: value hypothetical zero-coupon exposures after one-year migrations.
# All monetary outputs use USD millions, matching the configured face values.

#' Read explicit model assumptions; do not infer recovery from a yield column.
read_valuation_assumptions <- function(path) {
  assumptions <- suppressWarnings(readr::read_csv(
    path, col_types = readr::cols(
      .default = readr::col_character(), horizon_years = readr::col_double(),
      recovery_rate = readr::col_double()
    ), name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  ))
  required <- c("horizon_years", "recovery_rate", "nr_policy", "spread_policy",
                "recovery_note")
  if (!all(required %in% names(assumptions)) || nrow(assumptions) != 1L ||
      nrow(readr::problems(assumptions)) || anyNA(assumptions[, required]) ||
      assumptions$horizon_years != 1 ||
      !is.finite(assumptions$recovery_rate) ||
      assumptions$recovery_rate < 0 || assumptions$recovery_rate > 1 ||
      !assumptions$nr_policy %in%
        c("condition_on_observed", "nr_to_initial_rating") ||
      assumptions$spread_policy != "flat_index_oas_continuous_proxy" ||
      !nzchar(trimws(assumptions$recovery_note))) {
    stop(paste0("Invalid assumptions: use one year and recovery in [0,1], ",
                "and supported NR/spread policies."), call. = FALSE)
  }
  as.data.frame(assumptions[, required])
}

#' Price every issuer/state and compute exact marginal expected horizon values.
#' @param registry Validated issuer register with hypothetical face amounts.
#' @param curve Same-date Treasury curve with continuous decimal zero rates.
#' @param spreads Seven rating-index decimal spread proxies on the curve date.
#' @param transition Named one-year stochastic matrix in credit_states() order.
#' @param recovery_rate Fixed fraction of face paid at the one-year horizon.
#' @param horizon_years Must be one: the source migration matrix is annual.
#' @param horizon_spread_shock_bps Additive horizon-only spread change in bps.
#' @return State-value matrix, conditional table and issuer/portfolio summaries.
#' @details At inception V0=N*exp(-(z(T)+s_initial)*T). At horizon h, use
#'   forward f(h,T)=(T*z(T)-h*z(h))/(T-h) and Vh=N*exp(-(f+s_state)*(T-h)).
#'   Default pays recovery_rate*N at h. Spreads are frozen flat proxies and
#'   are not risk-neutral transition intensities. Expected values use physical
#'   migration probabilities; dependence is irrelevant to this linear mean.
value_migration_states <- function(registry, curve, spreads, transition,
                                    recovery_rate = 0.4, horizon_years = 1,
                                    horizon_spread_shock_bps = 0) {
  validate_transition_matrix(transition)
  if (!is.numeric(recovery_rate) || length(recovery_rate) != 1L ||
      is.na(recovery_rate) || !is.finite(recovery_rate) ||
      recovery_rate < 0 || recovery_rate > 1 ||
      !is.numeric(horizon_years) || length(horizon_years) != 1L ||
      is.na(horizon_years) || horizon_years != 1) {
    stop("Use recovery in [0,1] and the supported one-year horizon.",
         call. = FALSE)
  }
  if (!is.numeric(horizon_spread_shock_bps) ||
      length(horizon_spread_shock_bps) != 1L ||
      !is.finite(horizon_spread_shock_bps)) {
    stop("Use one finite horizon-only spread shock in basis points.",
         call. = FALSE)
  }
  states <- credit_states()
  required <- c("issuer_id", "rating_bucket", "currency",
                "notional_usd_million", "maturity_years")
  if (!is.data.frame(registry) || !nrow(registry) ||
      !all(required %in% names(registry)) || anyNA(registry[required]) ||
      anyDuplicated(registry$issuer_id) || any(registry$currency != "USD") ||
      any(!registry$rating_bucket %in% head(states, -1L)) ||
      !is.numeric(registry$notional_usd_million) ||
      !is.numeric(registry$maturity_years) ||
      any(!is.finite(registry$notional_usd_million) |
            registry$notional_usd_million <= 0) ||
      any(!is.finite(registry$maturity_years) |
            registry$maturity_years <= horizon_years)) {
    stop("Invalid USD portfolio, initial rating or remaining maturity.",
         call. = FALSE)
  }
  curve_fields <- c("observation_date", "maturity_years",
                     "zero_rate_continuous")
  spread_fields <- c("observation_date", "rating_bucket",
                      "spread_decimal_proxy")
  if (!is.data.frame(curve) || !all(curve_fields %in% names(curve)) ||
      !is.data.frame(spreads) || !all(spread_fields %in% names(spreads)) ||
      anyNA(curve[curve_fields]) || anyNA(spreads[spread_fields]) ||
      !inherits(curve$observation_date, "Date") ||
      !inherits(spreads$observation_date, "Date") ||
      length(unique(curve$observation_date)) != 1L ||
      length(unique(spreads$observation_date)) != 1L ||
      unique(curve$observation_date) != unique(spreads$observation_date) ||
      !is.numeric(curve$maturity_years) ||
      any(!is.finite(curve$maturity_years) | curve$maturity_years <= 0) ||
      anyDuplicated(curve$maturity_years) ||
      anyDuplicated(spreads$rating_bucket) ||
      !setequal(spreads$rating_bucket, head(states, -1L)) ||
      !is.numeric(curve$zero_rate_continuous) ||
      !is.numeric(spreads$spread_decimal_proxy) ||
      any(!is.finite(curve$zero_rate_continuous)) ||
      any(!is.finite(spreads$spread_decimal_proxy))) {
    stop("Supply finite, complete Treasury and spread inputs on a shared date.",
         call. = FALSE)
  }
  required_tenors <- c(horizon_years, registry$maturity_years)
  if (!all(required_tenors %in% curve$maturity_years)) {
    stop("The curve lacks a required exact tenor; no extrapolation is applied.",
         call. = FALSE)
  }
  h <- horizon_years
  maturity <- registry$maturity_years
  remaining <- maturity - h
  face <- registry$notional_usd_million
  z_h <- curve$zero_rate_continuous[match(h, curve$maturity_years)]
  z_t <- curve$zero_rate_continuous[match(maturity, curve$maturity_years)]
  forward <- (maturity * z_t - h * z_h) / remaining
  s <- spreads$spread_decimal_proxy[match(head(states, -1L),
                                          spreads$rating_bucket)]
  initial_spread <- s[match(registry$rating_bucket, head(states, -1L))]
  initial_value <- face * exp(-(z_t + initial_spread) * maturity)
  horizon_spread <- s + horizon_spread_shock_bps / 10000
  values <- face * exp(-outer(remaining * forward, rep(1, 7L)) -
                         outer(remaining, horizon_spread))
  values <- cbind(values, recovery_rate * face)
  dimnames(values) <- list(registry$issuer_id, states)
  if (any(!is.finite(values)) || any(values < 0) ||
      any(values[, head(states, -1L), drop = FALSE] <= 0) ||
      any(!is.finite(initial_value) | initial_value <= 0)) {
    stop("The supplied rates produce invalid valuation amounts.", call. = FALSE)
  }
  no_migration <- values[cbind(seq_along(face),
                               match(registry$rating_bucket, states))]
  probabilities <- transition[registry$rating_bucket, , drop = FALSE]
  rownames(probabilities) <- registry$issuer_id
  expected <- rowSums(probabilities * values)
  risk_free_roll <- initial_value * exp(z_h * h)
  if (any(!is.finite(risk_free_roll))) {
    stop("Invalid risk-free rolled benchmark.", call. = FALSE)
  }
  issuer_summary <- data.frame(
    issuer_id = registry$issuer_id, initial_rating = registry$rating_bucket,
    face_usd_million = face, maturity_years = maturity,
    remaining_years_at_horizon = remaining, forward_rate_continuous = forward,
    initial_value_usd_million = initial_value,
    no_migration_value_usd_million = no_migration,
    expected_value_usd_million = expected,
    expected_credit_loss_usd_million = no_migration - expected,
    expected_total_pnl_usd_million = expected - initial_value,
    risk_free_rolled_initial_usd_million = risk_free_roll,
    expected_loss_vs_rf_usd_million = risk_free_roll - expected,
    model_default_probability = probabilities[, "D"],
    recovery_value_usd_million = recovery_rate * face, row.names = NULL
  )
  money_columns <- c(
    "face_usd_million", "initial_value_usd_million",
    "no_migration_value_usd_million", "expected_value_usd_million",
    "expected_credit_loss_usd_million", "expected_total_pnl_usd_million",
    "risk_free_rolled_initial_usd_million", "expected_loss_vs_rf_usd_million"
  )
  portfolio <- as.data.frame(lapply(issuer_summary[money_columns], sum))
  conditional <- do.call(rbind, lapply(seq_along(face), function(i) {
    data.frame(
      issuer_id = registry$issuer_id[i],
      initial_rating = registry$rating_bucket[i],
      horizon_rating = states, probability = probabilities[i, ],
      value_usd_million = values[i, ],
      credit_loss_usd_million = no_migration[i] - values[i, ],
      total_pnl_usd_million = values[i, ] - initial_value[i], row.names = NULL
    )
  }))
  list(state_values = values, issuer_summary = issuer_summary,
       portfolio_summary = portfolio, conditional = conditional)
}
