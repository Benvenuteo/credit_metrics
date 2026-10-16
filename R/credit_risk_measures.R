# Purpose: estimate discrete-loss VaR/ES and report Monte Carlo uncertainty.
# Losses are signed: gains remain negative and are never floored at zero.

#' Validate strictly interior, distinct confidence levels.
check_credit_risk_levels <- function(levels) {
  if (!is.numeric(levels) || !length(levels) || anyNA(levels) ||
      any(!is.finite(levels)) || any(levels <= 0 | levels >= 1) ||
      anyDuplicated(levels)) {
    stop("Risk confidence levels must be distinct finite numbers in (0,1).",
         call. = FALSE)
  }
  sort(levels)
}

#' Return normalized worst-tail weights, sharing boundary mass across ties.
#' @return Non-negative scenario weights summing to one.
#' @details The exact tail mass is N*(1-alpha), which need not be an integer.
credit_tail_weights <- function(losses, alpha, value_at_risk) {
  n <- length(losses)
  mass <- n * (1 - alpha)
  above <- losses > value_at_risk
  boundary <- losses == value_at_risk
  count_boundary <- sum(boundary)
  residual <- mass - sum(above)
  tolerance <- 1e-9 * max(1, mass)
  if (!count_boundary || residual < -tolerance ||
      residual > count_boundary + tolerance) {
    stop("The VaR threshold cannot allocate the requested empirical tail.",
         call. = FALSE)
  }
  fraction <- min(1, max(0, residual / count_boundary))
  (as.numeric(above) + fraction * boundary) / mass
}

#' Estimate inverse-ECDF VaR and quantile-integral ES for signed losses.
#' @param losses Finite numeric scenario losses, with no missing observations.
#' @param levels Confidence levels such as 0.95, 0.99 and 0.999.
#' @param mc_confidence Confidence for Monte Carlo intervals, normally 0.95.
#' @param support Known theoretical loss bounds, not the observed sample range.
#' @return Tail estimates, atom counts, rank intervals and MC standard errors.
#' @details ES=q+mean(max(L-q,0))/(1-alpha), including needed mass at VaR.
#'   VaR intervals invert binomial order-statistic ranks and are conservative
#'   with atoms. ES intervals are normal excess-payoff approximations and are
#'   omitted unless the VaR rank interval resolves to the same finite value.
#'   These intervals concern iid simulation error, not parameter/model risk.
summarize_credit_tail <- function(
    losses, levels = c(0.95, 0.99, 0.999), mc_confidence = 0.95,
    support = c(-Inf, Inf)) {
  levels <- check_credit_risk_levels(levels)
  if (!is.numeric(losses) || length(losses) < 2L ||
      any(!is.finite(losses))) {
    stop("Supply at least two finite loss scenarios without missing values.",
         call. = FALSE)
  }
  if (!is.numeric(mc_confidence) || length(mc_confidence) != 1L ||
      is.na(mc_confidence) || !is.finite(mc_confidence) ||
      mc_confidence <= 0 || mc_confidence >= 1 ||
      !is.numeric(support) || length(support) != 2L || anyNA(support) ||
      support[1L] > support[2L]) {
    stop("Use an interior MC confidence and ordered known support bounds.",
         call. = FALSE)
  }
  scale <- max(1, max(abs(losses)))
  if (any(losses < support[1L] - 1e-10 * scale |
            losses > support[2L] + 1e-10 * scale)) {
    stop("Observed losses lie outside the supplied theoretical support.",
         call. = FALSE)
  }
  n <- length(losses)
  ordered <- sort(losses)
  quantiles <- stats::quantile(losses, levels, type = 1L, names = FALSE)
  delta <- (1 - mc_confidence) / 2
  normal_cutoff <- stats::qnorm(1 - delta)
  rows <- lapply(seq_along(levels), function(i) {
    alpha <- levels[i]
    q <- quantiles[i]
    lower_rank <- stats::qbinom(delta, n, alpha)
    upper_rank <- stats::qbinom(1 - delta, n, alpha) + 1
    lower <- if (lower_rank >= 1) ordered[lower_rank] else support[1L]
    upper <- if (upper_rank <= n) ordered[upper_rank] else support[2L]
    excess <- pmax(losses - q, 0)
    es <- q + mean(excess) / (1 - alpha)
    weights <- credit_tail_weights(losses, alpha, q)
    allocated_es <- sum(weights * losses)
    if (abs(es - allocated_es) > 1e-9 * max(1, abs(es))) {
      stop("Excess-loss ES and boundary-weighted ES disagree.", call. = FALSE)
    }
    es_se <- stats::sd(excess) / ((1 - alpha) * sqrt(n))
    stable <- is.finite(lower) && is.finite(upper) && lower == upper &&
      lower == q
    data.frame(
      confidence_level = alpha, n_scenarios = n,
      var_usd_million = q, es_usd_million = es,
      nominal_tail_scenarios = n * (1 - alpha),
      count_strictly_above_var = sum(losses > q),
      count_equal_to_var = sum(losses == q),
      fraction_of_var_atom_in_tail =
        sum(weights[losses == q]) * n * (1 - alpha) /
        sum(losses == q),
      var_mc_ci_lower = lower, var_mc_ci_upper = upper,
      var_ci_lower_rank = lower_rank, var_ci_upper_rank = upper_rank,
      var_resolved_at_mc_confidence = stable,
      es_mc_se_approx = es_se,
      es_mc_ci_lower_approx = if (stable) {
        es - normal_cutoff * es_se
      } else NA_real_,
      es_mc_ci_upper_approx = if (stable) {
        es + normal_cutoff * es_se
      } else NA_real_,
      mc_confidence_level = mc_confidence
    )
  })
  do.call(rbind, rows)
}

#' Allocate portfolio ES to issuers using the same fractional boundary weights.
#' @return Per-issuer ES contributions; they sum to each portfolio ES estimate.
allocate_credit_es <- function(simulation, valuation, tail_summary) {
  ids <- valuation$issuer_summary$issuer_id
  values <- valuation$state_values
  losses <- simulation$losses
  destinations <- simulation$destinations
  if (!is.matrix(destinations) || nrow(destinations) != length(losses) ||
      !identical(colnames(destinations), ids)) {
    stop("Scenario state columns must match valuation issuer IDs.",
         call. = FALSE)
  }
  rows <- lapply(seq_len(nrow(tail_summary)), function(j) {
    row <- tail_summary[j, ]
    weights <- credit_tail_weights(losses, row$confidence_level,
                                    row$var_usd_million)
    contributions <- vapply(seq_along(ids), function(i) {
      one_loss <- valuation$issuer_summary$no_migration_value_usd_million[i] -
        values[i, destinations[, i]]
      sum(weights * one_loss)
    }, numeric(1))
    if (abs(sum(contributions) - row$es_usd_million) >
        1e-9 * max(1, abs(row$es_usd_million))) {
      stop("Issuer ES allocations do not sum to portfolio ES.", call. = FALSE)
    }
    data.frame(
      confidence_level = row$confidence_level, issuer_id = ids,
      es_contribution_usd_million = contributions,
      es_share = if (row$es_usd_million != 0) {
        contributions / row$es_usd_million
      } else NA_real_,
      exact_mean_loss_usd_million =
        valuation$issuer_summary$expected_credit_loss_usd_million,
      es_above_mean_contribution_usd_million = contributions -
        valuation$issuer_summary$expected_credit_loss_usd_million
    )
  })
  do.call(rbind, rows)
}

#' Compare nested Monte Carlo prefixes; these are not independent replications.
credit_convergence_table <- function(simulation, levels, mc_confidence = 0.95) {
  n <- length(simulation$losses)
  checkpoints <- sort(unique(pmin(c(10000, 50000, 100000, 500000, n), n)))
  rows <- lapply(checkpoints, function(size) {
    losses <- simulation$losses[seq_len(size)]
    estimates <- summarize_credit_tail(
      losses, levels, mc_confidence, support = simulation$loss_support
    )
    estimates$simulated_mean_loss_usd_million <- mean(losses)
    estimates$mean_mc_se_usd_million <- stats::sd(losses) / sqrt(size)
    estimates$exact_mean_loss_usd_million <-
      simulation$diagnostics$exact_mean_loss_usd_million
    estimates
  })
  do.call(rbind, rows)
}
