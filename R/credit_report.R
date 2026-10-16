# Purpose: reconstruct report tables from frozen stress inputs and outcomes.
# Rendering never downloads observations or claims a missing empirical backtest.

#' Revalue archived states and independently reconstruct report data.
load_credit_report_data <- function(snapshot_dir, primary_level = 0.99) {
  input_path <- file.path(snapshot_dir, "stress_inputs.rds")
  if (!file.exists(input_path)) {
    stop("Select a stage-05 snapshot containing stress_inputs.rds.",
         call. = FALSE)
  }
  saved <- readRDS(input_path)
  bundle <- saved$baseline_inputs
  control <- validate_credit_stress_source(
    bundle, saved$metadata$analysis_cutoff
  )
  if (length(primary_level) != 1L || !is.numeric(primary_level) ||
      !is.finite(primary_level) || !primary_level %in% control$levels) {
    stop("The report's primary confidence must exist in the saved risk levels.",
         call. = FALSE)
  }
  definitions <- saved$scenarios
  if (!is.data.frame(definitions) || !nrow(definitions) ||
      anyNA(definitions$scenario_id) ||
      anyDuplicated(definitions$scenario_id) ||
      definitions$scenario_id[1L] != "baseline" ||
      any(!grepl("^[a-z][a-z0-9_]*$", definitions$scenario_id))) {
    stop("Invalid archived scenario identities.", call. = FALSE)
  }
  paths <- input_path
  risks <- allocations <- portfolios <- diagnostics <- comparisons <- list()
  tag <- function(x, id) data.frame(scenario_id = id, x, row.names = NULL)
  for (i in seq_len(nrow(definitions))) {
    id <- definitions$scenario_id[i]
    case_paths <- file.path(snapshot_dir, id,
                              c("case_inputs.rds", "scenarios.rds"))
    if (!all(file.exists(case_paths))) {
      stop(paste("Incomplete archived scenario:", id), call. = FALSE)
    }
    paths <- c(paths, case_paths)
    archived <- readRDS(case_paths[1L])
    outcome <- readRDS(case_paths[2L])
    case <- build_credit_stress_case(bundle$valuation_inputs,
                                      bundle$correlation, definitions[i, ])
    if (!isTRUE(all.equal(case$valuation$state_values,
                           archived$case$valuation$state_values,
                           tolerance = 1e-12)) ||
        !isTRUE(all.equal(case$benchmark_values,
                           archived$case$benchmark_values,
                           tolerance = 1e-12)) ||
        !isTRUE(all.equal(case$correlation, archived$case$correlation,
                           tolerance = 1e-12))) {
      stop(paste("Case inputs differ from reconstructed pricing:", id),
           call. = FALSE)
    }
    ids <- case$registry$issuer_id
    destination <- outcome$destinations
    n <- control$settings$n_scenarios
    if (!is.matrix(destination) || !is.numeric(destination) ||
        !identical(dim(destination), c(as.integer(n), length(ids))) ||
        !identical(colnames(destination), ids) ||
        any(!is.finite(destination)) ||
        any(destination != floor(destination) | destination < 1 |
              destination > length(credit_states())) ||
        !is.numeric(outcome$losses) || length(outcome$losses) != n ||
        any(!is.finite(outcome$losses))) {
      stop(paste("Invalid archived destinations/losses:", id), call. = FALSE)
    }
    horizon <- numeric(n)
    for (j in seq_along(ids)) {
      horizon <- horizon + case$valuation$state_values[j, destination[, j]]
    }
    losses <- unname(sum(case$benchmark_values) - horizon)
    if (!isTRUE(all.equal(losses, outcome$losses, tolerance = 1e-12))) {
      stop(paste("Archived losses do not match their destination values:", id),
           call. = FALSE)
    }
    exact <- case$portfolio$exact_mean_loss_usd_million
    mean_se <- stats::sd(losses) / sqrt(n)
    error <- mean(losses) - exact
    z <- if (mean_se > 0) error / mean_se else NA_real_
    diagnostic <- data.frame(
      n_scenarios = n, exact_mean_loss_usd_million = exact,
      simulated_mean_loss_usd_million = mean(losses),
      mean_mc_se_usd_million = mean_se, mean_error_z = z,
      mean_within_six_mc_se = if (mean_se > 0) abs(z) <= 6 else
        abs(error) <= 1e-10
    )
    simulation <- list(losses = losses, destinations = destination,
                         benchmark_values = case$benchmark_values,
                         diagnostics = diagnostic)
    values <- case$valuation$state_values
    support <- sum(case$benchmark_values) -
      c(sum(apply(values, 1L, max)), sum(apply(values, 1L, min)))
    risk <- summarize_credit_tail(losses, control$levels,
                                    control$settings$mc_confidence_level,
                                    support = support)
    contribution <- allocate_credit_es(simulation, case$valuation, risk)
    if (i == 1L) {
      baseline <- simulation
      baseline_risk <- risk
      baseline_valuation <- case$valuation
    } else {
      comparisons[[i - 1L]] <- tag(compare_credit_stress_risk(
        baseline, baseline_risk, simulation, risk,
        control$settings$mc_confidence_level
      ), id)
    }
    risks[[i]] <- tag(risk, id)
    allocations[[i]] <- tag(contribution, id)
    portfolios[[i]] <- tag(case$portfolio, id)
    diagnostics[[i]] <- tag(diagnostic, id)
  }
  list(risk = do.call(rbind, risks),
       contributions = do.call(rbind, allocations),
       portfolios = do.call(rbind, portfolios),
       diagnostics = do.call(rbind, diagnostics),
       comparisons = do.call(rbind, comparisons),
       baseline_losses = baseline$losses,
       baseline_valuation = baseline_valuation,
       bundle = bundle, definitions = definitions, metadata = saved$metadata,
       primary_level = primary_level, source_paths = paths)
}

#' Format numeric report cells with explicit unavailable-value handling.
report_number <- function(x, digits = 2L) {
  answer <- rep("—", length(x))
  valid <- is.finite(x)
  answer[valid] <- formatC(x[valid], format = "f", digits = digits,
                            big.mark = " ", decimal.mark = ",")
  answer
}

#' Map default case IDs to Polish labels without hiding custom definitions.
report_scenario_label <- function(ids, definitions) {
  labels <- c(
    baseline = "Wariant bazowy", correlation_50 = "Korelacje: mieszanka 50%",
    correlation_85 = "Korelacje: mieszanka 85%", spread_100 = "Spready +100 pb",
    recovery_20 = "Odzysk 20%", combined_adverse = "Szoki łączne",
    equal_face = "Równe nominały", weakest_50 = "50% w najsłabszej grupie"
  )
  answer <- unname(labels[ids])
  missing <- is.na(answer)
  answer[missing] <- definitions$label[match(ids[missing],
                                             definitions$scenario_id)]
  answer
}

#' Draw the upper empirical CDF of simulated losses, without smoothing atoms.
plot_credit_report_tail <- function(data) {
  old <- graphics::par(mar = c(4.4, 4.6, 1, 1), las = 1)
  on.exit(graphics::par(old))
  losses <- data$baseline_losses
  x <- sort(unique(losses))
  counts <- tabulate(match(losses, x), nbins = length(x))
  cdf <- cumsum(counts) / length(losses)
  lower <- as.numeric(stats::quantile(losses, 0.9, type = 1))
  graphics::plot(x, cdf, type = "s", col = "#176b80", lwd = 2,
                   xlim = c(lower, max(x)), ylim = c(0.9, 1), bty = "l",
                   xlab = "Strata względem wartości bez migracji [mln USD]",
                   ylab = "Dystrybuanta empiryczna")
  baseline <- data$risk[data$risk$scenario_id == "baseline", ]
  colors <- grDevices::hcl.colors(nrow(baseline), "Dark 3")
  graphics::abline(h = baseline$confidence_level, col = "#d8dfe5", lty = 3)
  graphics::abline(v = baseline$var_usd_million, col = colors, lty = 2)
  graphics::legend("bottomright", bty = "n", col = colors, lty = 2,
                     legend = paste0("VaR ",
                                       report_number(100 *
                                         baseline$confidence_level, 1), "%"))
}

#' Compare stress ES using a shared face budget and explicit scenario labels.
plot_credit_report_stress <- function(data) {
  rows <- data$risk[data$risk$confidence_level == data$primary_level, ]
  rows <- rows[order(rows$es_usd_million), ]
  labels <- report_scenario_label(rows$scenario_id, data$definitions)
  labels <- vapply(labels, function(x) paste(strwrap(x, 26), collapse = "\n"),
                     character(1))
  old <- graphics::par(mar = c(4.4, 12.5, 1, 2), las = 1)
  on.exit(graphics::par(old))
  colors <- ifelse(rows$scenario_id == "baseline", "#176b80",
                     ifelse(rows$scenario_id == "combined_adverse",
                              "#a8473c", "#8baab8"))
  limits <- range(c(0, rows$es_usd_million))
  span <- max(diff(limits), 1)
  positions <- graphics::barplot(rows$es_usd_million, horiz = TRUE,
                                   names.arg = labels, border = NA,
                                   col = colors,
                                   xlim = limits + c(-0.03, 0.18) * span,
                                   cex.names = 0.85,
                                   xlab = "Expected Shortfall [mln USD]")
  graphics::abline(v = 0, col = "#455b6b", lwd = 0.6)
  graphics::text(rows$es_usd_million, positions,
                   labels = report_number(rows$es_usd_million),
                   pos = 4, cex = 0.82, offset = 0.5)
}

#' Show signed issuer contributions to the selected portfolio ES.
plot_credit_report_contributions <- function(data) {
  rows <- data$contributions[data$contributions$scenario_id == "baseline" &
                               data$contributions$confidence_level ==
                               data$primary_level, ]
  rows <- rows[order(rows$es_contribution_usd_million), ]
  old <- graphics::par(mar = c(4.4, 5.5, 1, 2), las = 1)
  on.exit(graphics::par(old))
  values <- rows$es_contribution_usd_million
  limits <- range(c(0, values))
  span <- max(diff(limits), 1)
  positions <- graphics::barplot(values, horiz = TRUE,
                                   names.arg = rows$issuer_id,
                                   col = "#176b80", border = NA,
                                   xlim = limits + c(-0.04, 0.2) * span,
                                   xlab = "Wkład do portfelowego ES [mln USD]")
  graphics::abline(v = 0, col = "#455b6b", lwd = 0.6)
  graphics::text(values, positions, labels = report_number(values),
                   pos = 4, cex = 0.9)
}

#' Display saved equity dependence with labels and a fixed [-1,1] color scale.
plot_credit_report_correlation <- function(data) {
  correlation <- data$bundle$correlation
  n <- nrow(correlation)
  old <- graphics::par(mar = c(4, 4, 1, 1), las = 1)
  on.exit(graphics::par(old))
  palette <- grDevices::colorRampPalette(c("#a8473c", "#f8fafc", "#176b80"))
  graphics::image(seq_len(n), seq_len(n), t(correlation[n:1L, ]),
                    zlim = c(-1, 1), col = palette(101), axes = FALSE,
                    xlab = "", ylab = "", asp = 1)
  graphics::axis(1, at = seq_len(n), labels = colnames(correlation),
                   tick = FALSE)
  graphics::axis(2, at = seq_len(n), labels = rev(rownames(correlation)),
                   tick = FALSE)
  for (i in seq_len(n)) for (j in seq_len(n)) {
    value <- correlation[n - j + 1L, i]
    graphics::text(i, j, report_number(value),
                     col = if (abs(value) > 0.65) "white" else "#143044")
  }
}

#' Archive frozen report inputs and render one self-contained Quarto HTML file.
#' @param renderer Optional injected render adapter for offline archive checks.
render_credit_portfolio_report <- function(
    stress_snapshot_dir, project_dir = ".", backtest_file = NULL,
    primary_level = 0.99, renderer = NULL,
    backtest_evaluation_date = default_equity_cutoff()) {
  validate_issuer_date(backtest_evaluation_date, "backtest_evaluation_date")
  if (backtest_evaluation_date > default_equity_cutoff()) {
    stop("Backtest evaluation must exclude the current New York day.",
         call. = FALSE)
  }
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  stress_snapshot_dir <- normalizePath(stress_snapshot_dir, winslash = "/",
                                         mustWork = TRUE)
  using_quarto <- is.null(renderer)
  if (using_quarto) {
    required <- c("knitr", "rmarkdown", "quarto")
    if (!all(vapply(required, requireNamespace, logical(1), quietly = TRUE))) {
      stop("Install knitr, rmarkdown and quarto in the project library.",
           call. = FALSE)
    }
    if (is.null(quarto::quarto_path())) {
      stop("Install the Quarto CLI: https://quarto.org/docs/get-started/",
           call. = FALSE)
    }
    renderer <- quarto::quarto_render
  }
  if (!is.function(renderer)) stop("renderer must be a function.",
                                   call. = FALSE)
  template_names <- c("credit_metrics.qmd", "report.css", "references.bib")
  templates <- file.path(project_dir, "reports", template_names)
  helper <- file.path(project_dir, "R", "credit_report.R")
  if (!all(file.exists(c(templates, helper)))) {
    stop("Report templates or the report helper source are missing.",
         call. = FALSE)
  }
  roots <- file.path(project_dir, "data", c("raw", "processed"), "reports")
  for (directory in roots) {
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE)) {
      stop("Cannot create report directories.", call. = FALSE)
    }
  }
  name <- basename(tempfile(paste0(
    "run_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_"
  ), tmpdir = roots[2L]))
  raw_dir <- file.path(roots[1L], name)
  output_dir <- file.path(roots[2L], name)
  created <- character()
  complete <- FALSE
  on.exit(if (!complete) unlink(created, recursive = TRUE), add = TRUE)
  if (!dir.create(raw_dir)) stop("Cannot create report archive.",
                                 call. = FALSE)
  created <- c(created, raw_dir)
  source_files <- c(file.path(stress_snapshot_dir, "stress_inputs.rds"),
                      list.files(stress_snapshot_dir,
                                   pattern = "^(case_inputs|scenarios)\\.rds$",
                                   recursive = TRUE, full.names = TRUE))
  relative <- substring(source_files, nchar(stress_snapshot_dir) + 2L)
  archived <- file.path(raw_dir, "stress_snapshot", relative)
  fingerprint <- unname(tools::md5sum(source_files))
  for (directory in unique(dirname(archived))) {
    dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  }
  if (!all(file.copy(source_files, archived)) ||
      !identical(unname(tools::md5sum(archived)), fingerprint)) {
    stop("Cannot archive unchanged report inputs.", call. = FALSE)
  }
  data <- load_credit_report_data(file.path(raw_dir, "stress_snapshot"),
                                    primary_level)
  # Keep an exact NULL field: removing it would enable partial name matching
  # against backtest_evaluation_date in downstream `$backtest` expressions.
  data["backtest"] <- list(NULL)
  data$backtest_evaluation_date <- backtest_evaluation_date
  if (!is.null(backtest_file)) {
    backtest_copy <- file.path(raw_dir, "var_backtest.csv")
    original_md5 <- unname(tools::md5sum(backtest_file))
    if (!isTRUE(file.copy(backtest_file, backtest_copy)) ||
        !identical(unname(tools::md5sum(backtest_copy)), original_md5)) {
      stop("Cannot archive the selected backtest input.", call. = FALSE)
    }
    data$backtest <- read_credit_var_backtest(
      backtest_copy, backtest_evaluation_date
    )
  }
  data$generated_at_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  data$report_r_version <- as.character(getRversion())
  data$quarto_cli_version <- if (using_quarto) {
    as.character(quarto::quarto_version())
  } else "custom_renderer"
  prepared_path <- file.path(raw_dir, "report_data.rds")
  saveRDS(data, prepared_path, version = 3)
  work <- file.path(raw_dir, "render")
  dir.create(work)
  copies <- c(file.path(work, template_names),
                file.path(work, "credit_report.R"))
  template_md5 <- unname(tools::md5sum(c(templates, helper)))
  if (!all(file.copy(c(templates, helper), copies)) ||
      !identical(unname(tools::md5sum(copies)), template_md5)) {
    stop("Cannot archive unchanged report templates.", call. = FALSE)
  }
  renderer(input = file.path(work, "credit_metrics.qmd"),
             output_file = "credit_metrics.html", output_format = "html",
             execute_params = list(report_data_file = prepared_path,
                                     helper_file = copies[4L]),
             execute_dir = work, cache = FALSE, quiet = TRUE, as_job = FALSE)
  rendered <- file.path(work, "credit_metrics.html")
  if (!file.exists(rendered) || file.info(rendered)$size < 100) {
    stop("The renderer did not create a complete HTML report.", call. = FALSE)
  }
  if (!dir.create(output_dir)) stop("Cannot create final report snapshot.",
                                    call. = FALSE)
  created <- c(created, output_dir)
  output <- file.path(output_dir, "credit_metrics.html")
  if (!isTRUE(file.copy(rendered, output))) {
    stop("Cannot save the rendered report.", call. = FALSE)
  }
  manifest <- data.frame(
    source = c(relative, paste0("reports/", template_names),
                  "R/credit_report.R"),
    md5 = c(fingerprint, template_md5)
  )
  if (!is.null(data$backtest)) {
    manifest <- rbind(manifest, data.frame(source = "var_backtest.csv",
                                            md5 = data$backtest$file_md5))
  }
  manifest <- rbind(manifest, data.frame(
    source = "report_data.rds", md5 = unname(tools::md5sum(prepared_path))
  ))
  readr::write_csv(manifest, file.path(output_dir, "input_manifest.csv"))
  readr::write_csv(data.frame(
    generated_at_utc = data$generated_at_utc,
    market_observation_date = data$metadata$market_observation_date,
    analysis_cutoff = data$metadata$analysis_cutoff,
    primary_confidence_level = primary_level,
    backtest_evaluation_date = backtest_evaluation_date,
    backtest_status = if (is.null(data$backtest)) "not_performed" else
      data$backtest$outcome_type,
    r_version = data$report_r_version,
    quarto_cli_version = data$quarto_cli_version
  ), file.path(output_dir, "render_metadata.csv"))
  readr::write_csv(data$risk, file.path(output_dir, "report_risk.csv"))
  readr::write_csv(data$comparisons,
                   file.path(output_dir, "report_comparisons.csv"))
  if (!is.null(data$backtest)) {
    readr::write_csv(data$backtest$summary,
                     file.path(output_dir, "var_backtest_tests.csv"))
  }
  complete <- TRUE
  message("Report created: ", output)
  list(html_file = output, snapshot_dir = output_dir,
       backtest_status = if (is.null(data$backtest)) "not_performed" else
         data$backtest$outcome_type)
}
