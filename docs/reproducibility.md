# Reproduce the analysis environment

The tested baseline is R 4.6.1, renv 1.3.1 and Quarto CLI 1.10.19. Package
versions are recorded in `renv.lock`, with a public Posit CRAN repository
snapshot dated 2026-10-16. The lockfile was generated from the environment used
to verify this repository, not copied from an inaccessible personal machine.

## Fresh clone

Clone the repository and open `credit_metrics.Rproj`, or use a terminal:

```sh
git clone https://github.com/Benvenuteo/credit_metrics.git
cd credit_metrics
Rscript -e 'renv::restore(prompt = FALSE)'
Rscript scripts/run_tests.R
```

On Windows, the same Git and Rscript commands work in PowerShell. R must be
available on PATH for terminal use; otherwise run the R commands in RStudio.
The committed `.Rprofile` loads `renv/activate.R` on normal R startup. The
bootstrap installs the recorded renv version when it is missing. Internet
access is required for package installation, not for the offline tests.

If an older local clone already has uncommitted renv/project files, preserve
those files before updating it. A fresh clone in a different directory is the
simplest way to use the committed environment without replacing that local
work. Do not rerun `renv::init()` in a clone that already has `renv.lock`.

The project library and caches are generated locally and ignored by Git.
`renv::status()` should report a synchronized environment after restoration.
Use the R version in the lockfile; renv manages packages, not the R executable.
When binaries are unavailable and packages must be compiled, Windows needs
matching Rtools. On Ubuntu 24.04, install the Linux system requirements with:

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential cmake \
  libcurl4-openssl-dev libssl-dev libuv1-dev libx11-dev libxml2-dev
```

These system components are not R packages and are not captured by `renv.lock`.
CI installs the additional development libraries explicitly. renv's implicit
discovery also includes Shiny for the report's parameter metadata; it is
recorded in the environment even though the report is a static HTML document.

## Reports

Reading `docs/index.html` needs only a browser. Rendering a new report also
needs the Quarto CLI; installing the R package named `quarto` does not install
that executable. Install CLI 1.10.19 and check its availability with:

```r
quarto::quarto_version()
```

The README describes the six analysis stages and explicit snapshot handoffs.
Market-data downloads remain separate from environment setup and automated
tests. A new live run can legitimately produce different results: sources,
ratings and the observation cutoff must be reviewed again. The committed HTML
remains the dated portfolio snapshot until a new reviewed render is copied
into `docs/index.html`.

## Continuous integration

`.github/workflows/r-tests.yml` runs on pushes to `main`, pull requests and
manual dispatch. It uses read-only repository permissions and pins its action
implementations to commit SHAs. On Ubuntu 24.04 and Windows 2025, it:

1. Installs the R version recorded in `renv.lock`.
2. Restores and caches the locked packages.
3. Requires `renv::status()$synchronized` to be true.
4. Parses all analysis, script and test R files and runs every offline suite.
5. Checks that validation did not modify the lockfile or project settings.

Linux additionally installs Quarto CLI 1.10.19 and runs real HTML renders for
both missing-backtest and synthetic-backtest inputs. These checks require
four embedded figures, no external assets and the correct evidence-status
label. Synthetic fixtures and temporary outputs are deleted afterwards;
these renders are never published as the portfolio analysis.

To run the same render checks locally, set the flag for one test invocation:

```r
Sys.setenv(CREDIT_METRICS_TEST_RENDER = "true")
source("tests/test_credit_report.R", encoding = "UTF-8")
Sys.unsetenv("CREDIT_METRICS_TEST_RENDER")
```

Environment synchronization, passing tests and successful renders establish
software consistency. They do not establish empirical forecast accuracy or
point-in-time availability of historical market data. The annual realized-loss
backtest remains unperformed, as stated in the report and validation methodology.

## Update dependencies deliberately

Restore the existing lockfile first. When a package change is intentional,
install/update it, run the test suites and real render checks, then record the
new environment with `renv::snapshot(prompt = FALSE)`. Review the lockfile diff
and the chosen repository snapshot before committing it. Ordinary analysis
runs should not regenerate the lockfile or update packages automatically.

The project uses implicit dependency discovery from saved R and Quarto source
files. A newly used package must appear in that source before snapshotting.
Only packages required by the analysis/report and their dependencies belong in
the lockfile; unrelated installed packages are not project requirements.

References: [renv collaboration](https://rstudio.github.io/renv/articles/collaborating.html),
[renv CI](https://rstudio.github.io/renv/articles/ci.html),
[r-lib actions](https://github.com/r-lib/actions),
[Quarto installation](https://quarto.org/docs/get-started/).
