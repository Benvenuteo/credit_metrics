# Purpose: extract a dated S&P corporate matrix and make NR treatment explicit.
# Provider observations are downloaded locally and are not bundled with code.

#' Return the model's fixed best-to-worst rating order.
credit_states <- function() c("AAA", "AA", "A", "BBB", "BB", "B", "CCC/C", "D")

#' Read the pinned study descriptor and enforce its manual review deadline.
#' @return One typed source-description row; no probabilities are embedded here.
read_transition_source <- function(path, review_date = Sys.Date()) {
  validate_issuer_date(review_date, "review_date")
  source <- suppressWarnings(readr::read_csv(
    path, col_types = readr::cols(
      .default = readr::col_character(),
      study_start_year = readr::col_integer(),
      study_end_year = readr::col_integer(),
      published_on = readr::col_date(), reviewed_on = readr::col_date(),
      review_due_on = readr::col_date()
    ), name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  ))
  required <- c("study_start_year", "study_end_year", "published_on",
                "reviewed_on", "review_due_on", "source_url")
  if (!all(required %in% names(source)) || nrow(source) != 1L ||
      nrow(readr::problems(source)) || anyNA(source[, required])) {
    stop("The transition source must be one complete, typed descriptor row.",
         call. = FALSE)
  }
  if (source$study_start_year < 1900L ||
      source$study_end_year < source$study_start_year ||
      source$study_end_year >= as.integer(format(source$published_on, "%Y")) ||
      source$published_on > source$reviewed_on ||
      source$reviewed_on > review_date ||
      source$review_due_on < source$reviewed_on ||
      !grepl("^https://www\\.spglobal\\.com/ratings/", source$source_url)) {
    stop("Invalid study years, review dates or S&P source URL.", call. = FALSE)
  }
  if (review_date > source$review_due_on) {
    stop("The transition study review has expired; check for a newer study.",
         call. = FALSE)
  }
  as.data.frame(source[, required])
}

#' Download one HTTPS input with finite timeouts and no cache substitution.
#' @return Retrieval metadata; the exact response bytes are written to path.
download_credit_input <- function(url, path, query = list()) {
  if (!is.character(url) || length(url) != 1L || is.na(url) ||
      !grepl("^https://", url)) {
    stop("Credit input URLs must use HTTPS.", call. = FALSE)
  }
  request <- httr2::request(url)
  if (length(query)) {
    request <- do.call(httr2::req_url_query, c(list(request), query))
  }
  request <- request |>
    httr2::req_user_agent("credit_metrics/0.3 (+portfolio research)") |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3, max_seconds = 120,
                    retry_on_failure = TRUE)
  response <- tryCatch(
    httr2::req_perform(request, path = path),
    error = function(error) {
      stop(paste("Credit input download failed:", conditionMessage(error)),
           call. = FALSE)
    }
  )
  fingerprint <- unname(tools::md5sum(path))
  if (is.na(fingerprint)) stop("Cannot fingerprint the input.", call. = FALSE)
  data.frame(
    source_url = httr2::resp_url(response),
    downloaded_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    http_status = httr2::resp_status(response), source_md5 = fingerprint
  )
}

#' Extract only the one-year section of the specified S&P global table.
#' @param path Downloaded public article HTML.
#' @param study_start_year First year in the selected historical sample.
#' @param study_end_year Last year in the selected historical sample.
#' @return Published percentages including NR, excluding standard deviations.
#' @details Supports direct article HTML and its public __NEXT_DATA__ payload.
#'   Unexpected titles, layouts or cells stop parsing rather than selecting a
#'   different geography, horizon, vintage or table of standard deviations.
read_sp_transition_table <- function(path, study_start_year, study_end_year) {
  options <- c("RECOVER", "NOERROR", "NOWARNING", "NONET")
  page <- xml2::read_html(path, options = options)
  payload <- xml2::xml_find_first(page, "//script[@id='__NEXT_DATA__']")
  if (!inherits(payload, "xml_missing")) {
    data <- tryCatch(jsonlite::fromJSON(xml2::xml_text(payload),
                                       simplifyVector = FALSE),
                     error = function(error) NULL)
    embedded <- data$props$pageProps$props[[1L]]$html
    if (!is.character(embedded) || length(embedded) != 1L) {
      stop("The S&P public article payload has an unexpected structure.",
           call. = FALSE)
    }
    # The public payload HTML is entity-escaped once in the current layout.
    for (i in seq_len(3L)) {
      if (grepl("<table", embedded, fixed = TRUE)) break
      embedded <- xml2::xml_text(xml2::read_html(
        paste0("<html><body>", embedded, "</body></html>"), options = options
      ))
    }
    page <- xml2::read_html(embedded, options = options)
  }
  title <- sprintf("Global corporate average transition rates (%d-%d) (%%)",
                   study_start_year, study_end_year)
  tables <- xml2::xml_find_all(page, ".//table")
  normalize_text <- function(x) trimws(gsub("[[:space:]]+", " ", x))
  titles <- vapply(tables, function(table) {
    paste(normalize_text(xml2::xml_text(xml2::xml_find_all(
      table, ".//th[@class='tableTitle']"
    ))), collapse = " ")
  }, character(1))
  selected <- which(titles == title)
  if (length(selected) != 1L) {
    stop("The requested global corporate table was not found uniquely.",
         call. = FALSE)
  }
  states <- credit_states()
  rows <- xml2::xml_find_all(tables[[selected]], "./tr|./tbody/tr")
  extracted <- list()
  header_ok <- FALSE
  one_year <- FALSE
  for (row in rows) {
    cells <- normalize_text(xml2::xml_text(
      xml2::xml_find_all(row, "./th|./td")
    ))
    if (!length(cells)) next
    if (identical(cells, c("From/to", states, "NR"))) header_ok <- TRUE
    if (cells[1L] == "One-year") {
      one_year <- TRUE
      next
    }
    if (one_year && cells[1L] %in% c("Three-year", "Five-year", "Seven-year")) {
      break
    }
    if (one_year && cells[1L] %in% head(states, -1L)) {
      if (!header_ok || length(cells) != 10L ||
          any(!grepl("^[0-9]+([.][0-9]+)?$", cells[-1L])) ||
          cells[1L] %in% names(extracted)) {
        stop("Malformed or duplicated S&P one-year probability cells.",
             call. = FALSE)
      }
      extracted[[cells[1L]]] <- as.numeric(cells[-1L])
    }
  }
  if (!header_ok || !setequal(names(extracted), head(states, -1L))) {
    stop("The S&P one-year section is incomplete or has changed labels.",
         call. = FALSE)
  }
  values <- do.call(rbind, extracted[head(states, -1L)])
  colnames(values) <- c(states, "NR")
  data.frame(from_rating = rownames(values), values,
             row.names = NULL, check.names = FALSE)
}

#' Validate a named one-year stochastic matrix with absorbing default.
validate_transition_matrix <- function(matrix, tolerance = 1e-10) {
  if (!is.numeric(tolerance) || length(tolerance) != 1L || is.na(tolerance) ||
      !is.finite(tolerance) || tolerance < 0 || tolerance > 1e-6) {
    stop("tolerance must be finite and between zero and 1e-6.", call. = FALSE)
  }
  states <- credit_states()
  if (!is.matrix(matrix) || !is.numeric(matrix) ||
      !identical(rownames(matrix), states) ||
      !identical(colnames(matrix), states) || any(!is.finite(matrix)) ||
      any(matrix < 0 | matrix > 1) ||
      any(abs(rowSums(matrix) - 1) > tolerance) ||
      any(abs(matrix["D", ] - as.numeric(states == "D")) > tolerance)) {
    stop("Invalid transition matrix: check probabilities and absorbing D.",
         call. = FALSE)
  }
  invisible(NULL)
}

#' Convert published percentages under an explicitly selected NR policy.
#' @param published Data frame with from_rating and nine destination columns.
#' @param nr_policy condition_on_observed or nr_to_initial_rating.
#' @param rounding_tolerance_pp Maximum rounding discrepancy from 100 percent.
#' @return A matrix and an audit of rounding, NR mass and PD changes.
#' @details Conditioning is a missing-outcome assumption and changes default
#'   probabilities. Holding NR at its original grade is another assumption.
#'   Neither turns an unobserved outcome into a measured credit state.
build_transition_matrix <- function(published, nr_policy,
                                    rounding_tolerance_pp = 0.05) {
  policies <- c("condition_on_observed", "nr_to_initial_rating")
  if (!is.character(nr_policy) || length(nr_policy) != 1L ||
      is.na(nr_policy) || !nr_policy %in% policies) {
    stop("Select an explicit supported NR policy.", call. = FALSE)
  }
  if (!is.numeric(rounding_tolerance_pp) ||
      length(rounding_tolerance_pp) != 1L || is.na(rounding_tolerance_pp) ||
      !is.finite(rounding_tolerance_pp) || rounding_tolerance_pp < 0 ||
      rounding_tolerance_pp > 0.05) {
    stop("rounding_tolerance_pp must be between zero and 0.05.", call. = FALSE)
  }
  states <- credit_states()
  ratings <- head(states, -1L)
  if (!is.data.frame(published) ||
      !all(c("from_rating", states, "NR") %in% names(published)) ||
      nrow(published) != 7L || anyNA(published$from_rating) ||
      anyDuplicated(published$from_rating) ||
      !setequal(published$from_rating, ratings) ||
      !all(vapply(published[c(states, "NR")], is.numeric, logical(1)))) {
    stop("Supply seven source ratings and nine numeric destination columns.",
         call. = FALSE)
  }
  published <- published[match(ratings, published$from_rating), ]
  percentages <- as.matrix(published[c(states, "NR")])
  if (any(!is.finite(percentages)) ||
      any(percentages < 0 | percentages > 100)) {
    stop("Published percentages must be finite and between zero and 100.",
         call. = FALSE)
  }
  totals <- rowSums(percentages)
  if (any(abs(totals - 100) > rounding_tolerance_pp + 1e-10)) {
    stop("Published rows do not total 100 percent within rounding tolerance.",
         call. = FALSE)
  }
  normalized <- percentages / totals
  matrix <- normalized[, states, drop = FALSE]
  if (nr_policy == "condition_on_observed") {
    if (any(rowSums(matrix) <= 0)) {
      stop("Cannot condition a row containing only NR outcomes.", call. = FALSE)
    }
    matrix <- matrix / rowSums(matrix)
  } else {
    matrix[cbind(seq_len(7L), seq_len(7L))] <-
      diag(matrix[, seq_len(7L)]) + normalized[, "NR"]
  }
  matrix <- rbind(matrix, as.numeric(states == "D"))
  dimnames(matrix) <- list(states, states)
  validate_transition_matrix(matrix)
  audit <- data.frame(
    from_rating = ratings, published_total_percent = totals,
    rounding_error_pp = totals - 100,
    published_nr_percent = percentages[, "NR"],
    normalized_unconditional_pd = normalized[, "D"],
    model_pd = matrix[ratings, "D"], nr_policy = nr_policy
  )
  list(matrix = matrix, audit = audit, published = published)
}
