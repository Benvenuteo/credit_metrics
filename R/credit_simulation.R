# Purpose: simulate Gaussian latent credit migrations in bounded-size batches.
# Low latent asset returns map to default; high returns map to better ratings.

#' Validate a finite integer control without silent truncation.
check_simulation_integer <- function(value, label, minimum = 1,
                                      maximum = .Machine$integer.max) {
  if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
      !is.finite(value) || value != floor(value) ||
      value < minimum || value > maximum) {
    stop(paste(label, "must be an integer in", minimum, "to", maximum),
         call. = FALSE)
  }
  invisible(NULL)
}

#' Construct a named Gaussian factor supporting singular PSD correlations.
#' @return Factor, reconstructed correlation and explicit roundoff diagnostics.
#' @details Eigenvalues in [-1e-8,0) are clipped only as numerical roundoff.
#'   Rows are rescaled to unit variance; the reconstruction change is recorded.
#'   Larger negative eigenvalues fail the existing PSD validator.
make_credit_gaussian_factor <- function(correlation, issuer_ids) {
  if (!is.character(issuer_ids) || !length(issuer_ids) || anyNA(issuer_ids) ||
      anyDuplicated(issuer_ids) || is.null(rownames(correlation)) ||
      is.null(colnames(correlation)) ||
      anyDuplicated(rownames(correlation)) ||
      anyDuplicated(colnames(correlation)) ||
      !setequal(rownames(correlation), issuer_ids) ||
      !setequal(colnames(correlation), issuer_ids)) {
    stop("Correlation row/column labels must match the unique issuer IDs.",
         call. = FALSE)
  }
  correlation <- correlation[issuer_ids, issuer_ids, drop = FALSE]
  validate_issuer_correlation(correlation)
  decomposition <- eigen(correlation, symmetric = TRUE)
  factor <- sweep(decomposition$vectors, 2L,
                   sqrt(pmax(decomposition$values, 0)), "*")
  factor <- factor / sqrt(rowSums(factor ^ 2))
  rownames(factor) <- issuer_ids
  reconstructed <- tcrossprod(factor)
  dimnames(reconstructed) <- list(issuer_ids, issuer_ids)
  list(
    factor = factor, correlation = reconstructed,
    input_correlation = correlation,
    minimum_input_eigenvalue = min(decomposition$values),
    clipped_eigenvalue_count = sum(decomposition$values < 0),
    maximum_reconstruction_change = max(abs(reconstructed - correlation))
  )
}

#' Convert annual migration rows into lower-tail Gaussian thresholds.
#' @return One map per issuer, excluding all zero-probability states.
#' @details Reverse the source's best-to-worst order before accumulating mass.
#'   qnorm probabilities are model transition probabilities, not sample ranks.
make_credit_rating_maps <- function(transition, initial_ratings, issuer_ids) {
  validate_transition_matrix(transition)
  states <- credit_states()
  if (!is.character(initial_ratings) || anyNA(initial_ratings) ||
      length(initial_ratings) != length(issuer_ids) ||
      !length(issuer_ids) || anyDuplicated(issuer_ids) ||
      any(!initial_ratings %in% states)) {
    stop("Supply one recognized initial rating per unique issuer ID.",
         call. = FALSE)
  }
  maps <- lapply(seq_along(issuer_ids), function(i) {
    probabilities <- rev(transition[initial_ratings[i], ])
    active <- which(probabilities > 0)
    probabilities <- probabilities[active] / sum(probabilities[active])
    cumulative <- head(cumsum(probabilities), -1L)
    list(indices = rev(seq_along(states))[active],
         thresholds = stats::qnorm(pmin(cumulative, 1)))
  })
  names(maps) <- issuer_ids
  maps
}

#' Map latent draws to integer columns of the canonical state-value matrix.
#' @details Intervals are open on the left and closed on the right. Infinite
#'   test inputs represent limits; generated normal draws are finite.
map_credit_states <- function(latent, maps) {
  if (!is.matrix(latent) || !is.numeric(latent) || anyNA(latent) ||
      !is.list(maps) || ncol(latent) != length(maps)) {
    stop("Supply a numeric latent matrix and one validated map per column.",
         call. = FALSE)
  }
  states <- matrix(0L, nrow(latent), ncol(latent),
                    dimnames = list(NULL, names(maps)))
  for (i in seq_along(maps)) {
    intervals <- findInterval(latent[, i], maps[[i]]$thresholds,
                               left.open = TRUE) + 1L
    states[, i] <- maps[[i]]$indices[intervals]
  }
  states
}

#' Execute a callback with a fixed RNG algorithm/seed and restore caller state.
with_credit_rng <- function(seed, callback) {
  check_simulation_integer(seed, "seed", minimum = 0)
  previous_kind <- RNGkind()
  had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  if (had_seed) previous_seed <- get(".Random.seed", envir = .GlobalEnv)
  on.exit({
    do.call(RNGkind, as.list(previous_kind))
    if (had_seed) {
      assign(".Random.seed", previous_seed, envir = .GlobalEnv)
    } else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) {
      rm(list = ".Random.seed", envir = .GlobalEnv)
    }
  }, add = TRUE)
  RNGkind("Mersenne-Twister", "Inversion", "Rejection")
  set.seed(seed)
  callback()
}

#' Simulate horizon values using named correlations and physical transitions.
#' @param valuation Output of value_migration_states().
#' @param transition Named annual migration matrix.
#' @param correlation Named issuer latent-correlation proxy.
#' @param n_scenarios Number of independent portfolio scenarios.
#' @param batch_size Maximum latent-draw batch; full latent draws are not saved.
#' @param seed Reproducible Mersenne-Twister/Inversion seed.
#' @return Losses, integer destination states, moments and marginal diagnostics.
#' @details Loss is the no-migration horizon benchmark minus scenario value.
#'   Rows consume consecutive random draws, so batch partitioning preserves the
#'   random sequence. Losses and compact integer states are retained for audit
#'   and ES allocation; continuous latent draws are summarized then discarded.
simulate_credit_migrations <- function(
    valuation, transition, correlation, n_scenarios = 1000000L,
    batch_size = 50000L, seed = 20261016L) {
  check_simulation_integer(n_scenarios, "n_scenarios", 2L, 50000000L)
  check_simulation_integer(batch_size, "batch_size", 1L, 1000000L)
  check_simulation_integer(seed, "seed", 0L)
  summary <- valuation$issuer_summary
  values <- valuation$state_values
  states <- credit_states()
  ids <- summary$issuer_id
  required <- c("issuer_id", "initial_rating",
                "no_migration_value_usd_million", "expected_value_usd_million")
  if (!is.data.frame(summary) || !length(ids) || anyDuplicated(ids) ||
      !all(required %in% names(summary)) || anyNA(summary[required]) ||
      !is.matrix(values) || !identical(rownames(values), ids) ||
      !identical(colnames(values), states) || any(!is.finite(values)) ||
      any(values < 0) ||
      any(!is.finite(summary$no_migration_value_usd_million)) ||
      any(!is.finite(summary$expected_value_usd_million))) {
    stop("Supply a complete, finite migration valuation.", call. = FALSE)
  }
  gaussian <- make_credit_gaussian_factor(correlation, ids)
  maps <- make_credit_rating_maps(transition, summary$initial_rating, ids)
  target <- transition[summary$initial_rating, , drop = FALSE]
  rownames(target) <- ids
  expected <- rowSums(target * values)
  no_migration <- values[cbind(seq_along(ids),
                               match(summary$initial_rating, states))]
  if (any(abs(expected - summary$expected_value_usd_million) > 1e-9) ||
      any(abs(no_migration - summary$no_migration_value_usd_million) > 1e-9)) {
    stop("Valuation means/benchmarks do not match the supplied transitions.",
         call. = FALSE)
  }
  n_issuers <- length(ids)
  benchmark <- sum(summary$no_migration_value_usd_million)
  exact_expected_value <- sum(summary$expected_value_usd_million)
  result <- with_credit_rng(seed, function() {
    losses <- numeric(n_scenarios)
    destinations <- matrix(0L, n_scenarios, n_issuers,
                             dimnames = list(NULL, ids))
    counts <- matrix(0, n_issuers, length(states),
                       dimnames = list(ids, states))
    latent_sums <- numeric(n_issuers)
    latent_cross <- matrix(0, n_issuers, n_issuers)
    for (start in seq.int(1L, n_scenarios, by = batch_size)) {
      end <- min(start + batch_size - 1L, n_scenarios)
      n <- end - start + 1L
      independent <- matrix(stats::rnorm(n * n_issuers),
                              nrow = n, byrow = TRUE)
      latent <- independent %*% t(gaussian$factor)
      destination <- map_credit_states(latent, maps)
      horizon <- numeric(n)
      for (i in seq_len(n_issuers)) {
        horizon <- horizon + values[i, destination[, i]]
        counts[i, ] <- counts[i, ] +
          tabulate(destination[, i], nbins = length(states))
      }
      losses[start:end] <- benchmark - horizon
      destinations[start:end, ] <- destination
      latent_sums <- latent_sums + colSums(latent)
      latent_cross <- latent_cross + crossprod(latent)
    }
    list(losses = losses, destinations = destinations, counts = counts,
         latent_sums = latent_sums, latent_cross = latent_cross)
  })
  covariance <- (result$latent_cross -
                   outer(result$latent_sums, result$latent_sums) /
                   n_scenarios) / (n_scenarios - 1L)
  latent_correlation <- stats::cov2cor(covariance)
  dimnames(latent_correlation) <- list(ids, ids)
  frequencies <- result$counts / n_scenarios
  marginal_se <- sqrt(target * (1 - target) / n_scenarios)
  residual <- frequencies - target
  standardized <- matrix(0, n_issuers, length(states))
  positive_se <- marginal_se > 0
  standardized[positive_se] <- residual[positive_se] / marginal_se[positive_se]
  if (any(result$counts[target == 0] > 0) ||
      any(result$counts[target == 1] != n_scenarios)) {
    stop("A simulated destination violates a zero/one transition probability.",
         call. = FALSE)
  }
  marginal <- do.call(rbind, lapply(seq_len(n_issuers), function(i) {
    data.frame(issuer_id = ids[i], horizon_rating = states,
                 count = result$counts[i, ], target_probability = target[i, ],
                 simulated_probability = frequencies[i, ],
                 binomial_mc_se = marginal_se[i, ],
                 standardized_error = standardized[i, ], row.names = NULL)
  }))
  mc_se <- stats::sd(result$losses) / sqrt(n_scenarios)
  exact_mean_loss <- benchmark - exact_expected_value
  mean_error <- mean(result$losses) - exact_mean_loss
  z_score <- if (mc_se > 0) mean_error / mc_se else NA_real_
  diagnostics <- data.frame(
    n_scenarios = n_scenarios, benchmark_usd_million = benchmark,
    exact_mean_loss_usd_million = exact_mean_loss,
    simulated_mean_loss_usd_million = mean(result$losses),
    mean_mc_se_usd_million = mc_se, mean_error_z = z_score,
    mean_within_six_mc_se = if (mc_se > 0) abs(z_score) <= 6 else
      abs(mean_error) <= 1e-10,
    max_abs_marginal_z = max(abs(standardized)),
    max_latent_correlation_error =
      max(abs(latent_correlation - gaussian$correlation)),
    minimum_input_eigenvalue = gaussian$minimum_input_eigenvalue,
    clipped_eigenvalue_count = gaussian$clipped_eigenvalue_count,
    maximum_reconstruction_change = gaussian$maximum_reconstruction_change
  )
  list(
    losses = result$losses, destinations = result$destinations,
    marginal_diagnostics = marginal, diagnostics = diagnostics,
    gaussian = gaussian, latent_correlation = latent_correlation,
    loss_support = c(benchmark - sum(apply(values, 1L, max)),
                       benchmark - sum(apply(values, 1L, min)))
  )
}
