# Purpose: build explicit credit sensitivities and paired risk comparisons.
# Shock sizes are chosen assumptions, not fitted macroeconomic forecasts.

#' Read sensitivity definitions and reject inconsistent scenario labels.
read_credit_stress_scenarios <- function(path, baseline_recovery) {
  if (!is.numeric(baseline_recovery) || length(baseline_recovery) != 1L ||
      !is.finite(baseline_recovery) || baseline_recovery < 0 ||
      baseline_recovery > 1) {
    stop("Supply one finite baseline recovery in [0,1].", call. = FALSE)
  }
  scenarios <- suppressWarnings(readr::read_csv(
    path, col_types = readr::cols(
      .default = readr::col_character(),
      correlation_mix = readr::col_double(),
      spread_shock_bps = readr::col_double(),
      recovery_rate = readr::col_double()
    ), name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  ))
  fields <- c("scenario_id", "label", "category", "correlation_mix",
                "spread_shock_bps", "recovery_rate", "allocation")
  if (!all(fields %in% names(scenarios)) || nrow(scenarios) < 2L ||
      nrow(readr::problems(scenarios)) || anyNA(scenarios[fields]) ||
      anyDuplicated(scenarios$scenario_id) ||
      any(!grepl("^[a-z][a-z0-9_]*$", scenarios$scenario_id)) ||
      any(!nzchar(trimws(scenarios$label))) ||
      any(!scenarios$category %in% c("baseline", "dependence", "spread",
                                     "recovery", "combined", "allocation")) ||
      any(!scenarios$allocation %in%
            c("original", "equal_face", "weakest_50")) ||
      any(!is.finite(as.matrix(scenarios[c("correlation_mix",
                                           "spread_shock_bps",
                                           "recovery_rate")])))) {
    stop("Supply complete, uniquely named, typed credit stress scenarios.",
         call. = FALSE)
  }
  if (any(scenarios$correlation_mix < 0 | scenarios$correlation_mix > 1) ||
      any(scenarios$spread_shock_bps < 0 |
            scenarios$spread_shock_bps > 10000) ||
      any(scenarios$recovery_rate < 0 | scenarios$recovery_rate > 1)) {
    stop("Use correlation/recovery in [0,1]; spread shocks in [0,10000] bps.",
         call. = FALSE)
  }
  correlation_changed <- scenarios$correlation_mix != 0
  spread_changed <- scenarios$spread_shock_bps != 0
  recovery_changed <- scenarios$recovery_rate != baseline_recovery
  allocation_changed <- scenarios$allocation != "original"
  changes <- correlation_changed + spread_changed + recovery_changed +
    allocation_changed
  baseline <- scenarios$category == "baseline"
  valid <- (baseline & changes == 0) |
    (scenarios$category == "dependence" & correlation_changed & changes == 1) |
    (scenarios$category == "spread" & spread_changed & changes == 1) |
    (scenarios$category == "recovery" & recovery_changed & changes == 1) |
    (scenarios$category == "allocation" & allocation_changed & changes == 1) |
    (scenarios$category == "combined" & changes >= 2 & !allocation_changed)
  if (sum(baseline) != 1L || scenarios$scenario_id[1L] != "baseline" ||
      !baseline[1L] || any(!valid)) {
    stop("Put an unchanged baseline first; categories must match their shocks.",
         call. = FALSE)
  }
  as.data.frame(scenarios[fields])
}

#' Increase off-diagonal correlations by convex mixing with an all-ones matrix.
#' @details C(lambda)=(1-lambda)*C+lambda*11'; PSD and unit diagonal persist.
stress_credit_correlation <- function(correlation, mixture) {
  validate_issuer_correlation(correlation)
  if (!is.numeric(mixture) || length(mixture) != 1L ||
      !is.finite(mixture) || mixture < 0 || mixture > 1) {
    stop("Correlation mixture must be a finite number in [0,1].",
         call. = FALSE)
  }
  stressed <- (1 - mixture) * correlation + mixture
  validate_issuer_correlation(stressed)
  stressed
}

#' Reallocate the same total face, including a group-based concentration case.
#' @details weakest_50 assigns half the face to the worst broad-rating group,
#'   preserving original relative weights within that group and its complement.
stress_credit_allocation <- function(registry, allocation) {
  if (!is.character(allocation) || length(allocation) != 1L ||
      !allocation %in% c("original", "equal_face", "weakest_50")) {
    stop("Choose original, equal_face or weakest_50 allocation.", call. = FALSE)
  }
  face <- registry$notional_usd_million
  if (!is.numeric(face) || length(face) < 2L || any(!is.finite(face)) ||
      any(face <= 0) || !is.finite(sum(face))) {
    stop("Allocation requires at least two finite positive face amounts.",
         call. = FALSE)
  }
  total <- sum(face)
  if (allocation == "equal_face") {
    registry$notional_usd_million <- rep(total / length(face), length(face))
  } else if (allocation == "weakest_50") {
    grades <- match(registry$rating_bucket, head(credit_states(), -1L))
    if (anyNA(grades) || length(unique(grades)) < 2L) {
      stop("weakest_50 requires at least two recognized rating groups.",
           call. = FALSE)
    }
    weakest <- grades == max(grades)
    registry$notional_usd_million[weakest] <-
      total * 0.5 * face[weakest] / sum(face[weakest])
    registry$notional_usd_million[!weakest] <-
      total * 0.5 * face[!weakest] / sum(face[!weakest])
  }
  registry
}

#' Build a horizon shock while preserving base prices and portfolio benchmarks.
build_credit_stress_case <- function(inputs, correlation, scenario) {
  registry <- stress_credit_allocation(inputs$registry, scenario$allocation)
  baseline <- value_migration_states(
    registry, inputs$curve, inputs$spreads, inputs$transition,
    inputs$assumptions$recovery_rate, inputs$assumptions$horizon_years
  )
  stressed <- value_migration_states(
    registry, inputs$curve, inputs$spreads, inputs$transition,
    scenario$recovery_rate, inputs$assumptions$horizon_years,
    horizon_spread_shock_bps = scenario$spread_shock_bps
  )
  benchmark <- stats::setNames(
    baseline$issuer_summary$no_migration_value_usd_million,
    registry$issuer_id
  )
  weights <- registry$notional_usd_million /
    sum(registry$notional_usd_million)
  portfolio <- data.frame(
    face_usd_million = sum(registry$notional_usd_million),
    face_hhi = sum(weights ^ 2), effective_issuer_count = 1 / sum(weights ^ 2),
    largest_face_weight = max(weights),
    initial_value_usd_million =
      sum(baseline$issuer_summary$initial_value_usd_million),
    fixed_benchmark_usd_million = sum(benchmark),
    shocked_no_migration_value_usd_million =
      sum(stressed$issuer_summary$no_migration_value_usd_million),
    expected_horizon_value_usd_million =
      sum(stressed$issuer_summary$expected_value_usd_million)
  )
  portfolio$no_migration_shock_loss_usd_million <-
    portfolio$fixed_benchmark_usd_million -
    portfolio$shocked_no_migration_value_usd_million
  portfolio$expected_migration_component_usd_million <-
    portfolio$shocked_no_migration_value_usd_million -
    portfolio$expected_horizon_value_usd_million
  portfolio$exact_mean_loss_usd_million <-
    portfolio$fixed_benchmark_usd_million -
    portfolio$expected_horizon_value_usd_million
  list(registry = registry, valuation = stressed, benchmark_values = benchmark,
       correlation = stress_credit_correlation(correlation,
                                                 scenario$correlation_mix),
       portfolio = portfolio)
}

#' Compare paired scenario losses; ES intervals require both quantiles resolved.
#' @details Shared innovations pair outcomes; variance reduction is not assured.
compare_credit_stress_risk <- function(baseline, baseline_risk,
                                       simulation, risk, mc_confidence) {
  if (length(baseline$losses) != length(simulation$losses) ||
      !identical(baseline_risk$confidence_level, risk$confidence_level)) {
    stop("Paired comparisons require matching scenarios and confidence levels.",
         call. = FALSE)
  }
  n <- length(simulation$losses)
  difference <- simulation$losses - baseline$losses
  mean_se <- stats::sd(difference) / sqrt(n)
  mean_difference <- mean(difference)
  cutoff <- stats::qnorm((1 + mc_confidence) / 2)
  rows <- lapply(seq_len(nrow(risk)), function(i) {
    alpha <- risk$confidence_level[i]
    base_q <- baseline_risk$var_usd_million[i]
    stress_q <- risk$var_usd_million[i]
    excess_difference <- (pmax(simulation$losses - stress_q, 0) -
                            pmax(baseline$losses - base_q, 0)) / (1 - alpha)
    es_difference <- risk$es_usd_million[i] -
      baseline_risk$es_usd_million[i]
    if (abs(es_difference - (stress_q - base_q + mean(excess_difference))) >
        1e-9 * max(1, abs(es_difference))) {
      stop("Paired excess-payoff ES difference is inconsistent.", call. = FALSE)
    }
    es_se <- stats::sd(excess_difference) / sqrt(n)
    stable <- baseline_risk$var_resolved_at_mc_confidence[i] &&
      risk$var_resolved_at_mc_confidence[i]
    data.frame(
      confidence_level = alpha, n_scenarios = n,
      delta_var_usd_million = stress_q - base_q,
      delta_es_usd_million = es_difference,
      delta_es_percent = if (baseline_risk$es_usd_million[i] > 0) {
        100 * es_difference / baseline_risk$es_usd_million[i]
      } else NA_real_,
      paired_es_mc_se_approx = es_se,
      paired_es_mc_ci_lower_approx = if (stable) {
        es_difference - cutoff * es_se
      } else NA_real_,
      paired_es_mc_ci_upper_approx = if (stable) {
        es_difference + cutoff * es_se
      } else NA_real_,
      both_var_resolved = stable,
      simulated_mean_delta_usd_million = mean_difference,
      exact_mean_delta_usd_million =
        simulation$diagnostics$exact_mean_loss_usd_million -
        baseline$diagnostics$exact_mean_loss_usd_million,
      paired_mean_mc_se = mean_se,
      paired_mean_mc_ci_lower = mean_difference - cutoff * mean_se,
      paired_mean_mc_ci_upper = mean_difference + cutoff * mean_se,
      mc_confidence_level = mc_confidence
    )
  })
  do.call(rbind, rows)
}
