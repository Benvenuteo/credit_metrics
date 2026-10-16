# Purpose: run every offline test suite from the project root.
# Usage: Rscript scripts/run_tests.R (after renv::restore()).
# A failed assertion stops execution and returns a nonzero process exit code.

if (!dir.exists("R") || !dir.exists("tests") ||
    !file.exists("config/issuers.csv")) {
  stop("Run this script from the credit_metrics project root.",
       call. = FALSE)
}

test_files <- sort(list.files("tests", pattern = "^test_.*\\.R$",
                              full.names = TRUE))
if (!length(test_files)) {
  stop("No offline test suites were found.", call. = FALSE)
}

# Parse analysis and entry-point code without executing market downloads.
r_files <- unlist(lapply(c("R", "scripts", "tests"), list.files,
                          pattern = "\\.R$", recursive = TRUE,
                          full.names = TRUE), use.names = FALSE)
for (path in sort(r_files)) parse(path, encoding = "UTF-8")

for (path in test_files) {
  cat("\nRunning", path, "\n")
  source(path, local = new.env(parent = globalenv()), encoding = "UTF-8")
}
cat("\nAll", length(test_files), "offline test suites passed.\n")
