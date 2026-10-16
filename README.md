# Credit Portfolio Risk Analytics in R

An ongoing rebuild of an academic CreditMetrics project into a reproducible
credit portfolio risk analysis. The first implemented stage imports and
validates the USD Treasury base yield curve. Portfolio valuation, rating
migrations, and VaR/Expected Shortfall are subsequent stages.

## Run the first data import

Open the cloned `credit_metrics` RStudio project. Run these commands in the
R console from the project root:

```r
# Install only if these packages are not already in the project library.
renv::install(c("httr2", "readr"))

source("scripts/01_download_yield_curve.R")

# Detect dependencies from the saved R files, then record their versions.
renv::settings$snapshot.type("implicit")
renv::snapshot(prompt = FALSE)
renv::status()
```

For a fresh clone without an existing renv environment, first run:

```r
install.packages("renv", repos = "https://cloud.r-project.org")
renv::init(bare = TRUE, restart = FALSE)
```

If a reviewed `renv.lock` is already present, use `renv::restore()` to recreate
its environment instead of initializing a new one. Commit your verified
lockfile, activation files, project settings, and source code to preserve
the working environment.

The import downloads the current Fed CSV, selects the latest eligible date,
validates freshness and completeness, and prints the 1-30 year curve. It also
creates an immutable processed snapshot containing `curve.csv` and
`metadata.csv`; the console prints its location. No API key is needed.

Fed GSW observations are daily but normally published weekly. The importer
allows up to 14 calendar days of publication lag. It raises an error for stale
data rather than pretending an older observation is current.

## Reuse a saved snapshot

The returned `yield_curve_result` contains the curve and provenance metadata.
Record its `snapshot_dir` when retaining a particular analysis. Within the
same R session, you can reread its saved data without a network request:

```r
saved_snapshot_dir <- yield_curve_result$snapshot_dir
saved_curve <- readr::read_csv(
  file.path(saved_snapshot_dir, "curve.csv"),
  col_types = readr::cols(observation_date = readr::col_date(),
                         .default = readr::col_double())
)
```

In another session, assign the previously recorded directory path to
`saved_snapshot_dir` before reading that snapshot.

The `as_of_date` argument filters observation dates in the downloaded vintage.
It does not provide historical, point-in-time availability of revised data.

## Validate the implementation

Run the offline checks from the project root:

```r
source("tests/test_fed_yield_curve.R")
```

The synthetic fixtures cover source parsing, date cutoffs, stale and incomplete
data, percent-to-decimal conversion, continuous discounting, valid negative
rates, duplicate dates, and invalid arguments. Network availability is not
required for these tests.

## Repository layout

| Path | Purpose |
| --- | --- |
| `R/fed_yield_curve.R` | Reusable import and validation functions |
| `scripts/01_download_yield_curve.R` | First analysis entry point |
| `tests/test_fed_yield_curve.R` | Offline checks using synthetic inputs |
| `docs/data_sources.md` | Sources, units, freshness policy, and limitations |
| `data/raw/` | Original source vintages, generated locally |
| `data/processed/` | Validated curves and provenance, generated locally |

See [data sources and conventions](docs/data_sources.md) for details.
