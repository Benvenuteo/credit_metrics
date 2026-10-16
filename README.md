# Credit Portfolio Risk Analytics in R

An ongoing rebuild of an academic CreditMetrics project into a reproducible
credit portfolio risk analysis. Implemented stages import the USD Treasury
base curve, maintain a sourced issuer register, collect daily equity prices,
estimate an issuer correlation proxy, value one-year rating migrations, and
simulate correlated portfolio losses with VaR, Expected Shortfall, Monte Carlo
uncertainty and issuer ES contributions. Implemented stress comparisons cover
dependence, horizon spreads, recovery and face allocation.

The portfolio design retains five hypothetical five-year zero-coupon exposures
with a total face value of USD 100 million. These are modeling assumptions,
not a list of real traded bonds or a continuation of a 2023 trade. Equity
prices supply a dependence proxy; they do not value these debt exposures.

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

## Run the issuer data import

From the same project root, run:

```r
renv::install("quantmod")
source("scripts/02_download_issuer_prices.R")

renv::settings$snapshot.type("implicit")
renv::snapshot(prompt = FALSE)
renv::status()
```

The script reads `config/issuers.csv`, collects three calendar years of daily
Yahoo Finance prices, and prints source dates, completeness checks and the
correlation matrix. It requires no API key. It always excludes the current
New York calendar day to avoid using an unfinished session. On weekends and
market holidays, the most recent source session is used, subject to a
seven-calendar-day freshness limit.

Successful runs create separate `data/raw/issuer_prices/run_.../` and
`data/processed/issuer_prices/run_.../` directories. The processed directory
contains prices, common log returns, a correlation matrix, a quality summary,
an exclusion audit, flagged extreme returns, the issuer registry and provenance.
The console prints the exact paths. These generated datasets are not committed
to Git. `source_exports.rds` preserves quantmod's returned objects, rather than
the provider's original HTTP responses.

The matrix uses the provider's `Adjusted` column and one common complete sample.
Missing prices are not filled. Returns are calculated before aligning dates;
both interval endpoints must agree across issuers. Default controls require
at least 500 common returns and 95% coverage. Extreme absolute log returns
above 0.35 are flagged for review and remain in the sample. Correlations are
computed at full precision and checked for positive semidefiniteness.

This is an equity-return proxy for issuer dependence. It is not a direct
measurement of asset correlation or default correlation. Provider adjustments
also need scrutiny around corporate actions; see the documented limitations.

## Review issuer ratings

The register records full long-term **S&P issuer ratings**, their broad model
buckets, source dates, source links, and a separate manual-review date. It does
not scrape ratings or claim to provide a live rating feed. The full rating
notch is retained even when the later migration model uses a broad bucket.
Issue-specific secured-debt ratings are not substituted for issuer ratings.

The initial public-source review was made on 2026-10-16. NetApp's most recent
explicit confirmation located in that review is dated 2025-03-12; that source
age is visible rather than presented as a new rating action. A public-source
review cannot guarantee that every subsequent action was accessible.

The importer stops when a review is older than 30 calendar days. Reopen the
primary sources, check for subsequent actions, and update the full rating,
bucket, evidence and review note before changing `rating_reviewed_on`.
Do not update that date automatically. A renewed review can leave the rating
and its original source date unchanged. Verify the rating status again before
publishing final credit-risk results.

## Run one-year migration valuation

From the project root, run:

```r
# jsonlite may already be installed as a quantmod dependency.
renv::install(c("xml2", "jsonlite"))
source("tests/test_migration_valuation.R")
source("scripts/03_value_migrations.R")

renv::snapshot(prompt = FALSE)
renv::status()
```

This entry point downloads fresh Fed and FRED inputs and the pinned S&P annual
study. It extracts the global one-year matrix, checks its probability totals,
and applies the explicit NR policy in `config/valuation_assumptions.csv`.
The full dated source HTML and CSV stay in the local archive. A page-layout
change or incomplete latest input stops the calculation rather than selecting
a different table or quietly reusing old data.

Treasury rates and rating spreads are aligned to their latest shared observation
date. That date can precede the requested cutoff because the Fed publishes on
a different schedule. Both dates and independent feed freshness remain visible
in the metadata. No API key is needed.

The result distinguishes current model value, the one-year no-migration
benchmark, the probability-weighted expected horizon value, credit loss versus
that benchmark, and total P&L including carry. All amounts are **USD millions**.
After one year the configured five-year zero-coupon exposures have four years
remaining. Default pays an assumed fraction of face at the horizon.

The baseline uses a fixed 40% recovery assumption and flat rating-index OAS
spread proxies. It compares 20%/40%/60% recovery and two explicit NR assumptions.
These are model choices: index OAS does not supply a bootstrapped issuer credit
curve, and 40% is not presented as a current empirical recovery estimate.
The mean is calculated exactly across destination states; dependence is needed
for the next stage's loss distribution.

Each successful run creates
`data/processed/migration_valuation/run_.../`, containing conditional valuations,
issuer/portfolio summaries, sensitivity results, transition audit, market
inputs and provenance. Its `model_inputs.rds` retains matrix labels, dates and
full numeric precision for the simulation stage. The console prints the path.

Read [model methodology](docs/model_methodology.md) for equations, benchmarks,
the NR assumptions and the limitations of the spread/recovery approximations.
Review `config/transition_source.csv` when a newer annual study is published;
the pinned descriptor has an explicit review deadline.

## Run correlated portfolio risk

After stage 03 in the same R session, run:

```r
source("tests/test_credit_simulation.R")
source("scripts/04_simulate_credit_risk.R")

renv::snapshot(prompt = FALSE)
renv::status()
```

No new package is required beyond the earlier stages. The script uses the
explicit `migration_valuation_result$snapshot_dir`; it never guesses the newest
directory. In a fresh session, run stage 03 first, or set that field to the
saved directory you deliberately selected. Its market date must be at most
14 calendar days before the current completed-day cutoff.

The pipeline downloads a fresh three-year equity sample ending **on the saved
valuation date**, then recomputes and validates the common-sample correlation.
It checks that issuer identities, ratings and exposures match the valuation.
An equity run previously ending on a later date is not reused implicitly.

Defaults in `config/simulation_settings.csv` and `config/risk_levels.csv` use
1,000,000 Gaussian migration scenarios, seed 20261016, batches of 50,000, and
95%/99%/99.9% risk levels. The smallest nominal tail contains 1,000 scenarios;
this is a precision policy, not a guarantee of stable tail estimates.

Loss is the **no-migration horizon value minus simulated horizon value**, in
USD millions. VaR uses the inverse empirical CDF. ES averages exactly the
requested worst-tail probability, sharing any needed mass at VaR across tied
scenarios. Gains remain negative. Issuer ES contributions sum to portfolio ES.

The console prints VaR/ES and diagnostics. A new
`data/processed/credit_simulation/run_.../` contains risk estimates, binomial
VaR intervals, approximate ES simulation errors, issuer ES contributions,
marginal/correlation diagnostics, nested convergence checks, dated calibration
returns, metadata, and compressed scenario/input RDS files. Exact model/config
copies are retained under `data/raw/credit_simulation/run_.../`.

Uncertainty intervals describe finite Monte Carlo sampling only. They do not
cover uncertain migrations, ratings, correlations, spreads or recovery. ES
normal intervals are omitted when the VaR rank interval spans multiple values.
See [simulation methodology](docs/simulation_methodology.md) for the formulas,
precision limits, replay procedure and independent analytical checks.

## Run sensitivity and stress comparisons

After stage 04 in the same R session, run:

```r
source("tests/test_credit_stress.R")
source("scripts/05_run_stress_tests.R")
```

No new package is required. Stage 05 takes the explicit
`credit_simulation_result$snapshot_dir`. It replays and checks the saved baseline
before comparing eight cases from `config/stress_scenarios.csv`. It reuses the
baseline's dates, seed, scenario count, risk levels and numeric market inputs;
it does not request fresh observations or read newly edited simulation controls.

Default cases are the unchanged baseline, two correlation mixtures toward
perfect dependence, a +100 bps horizon spread shock, 20% recovery, a combined
sensitivity, equal face amounts and 50% of face in the weakest rating group.
Shock sizes are chosen sensitivity assumptions, not estimated crisis forecasts
or probabilities. Historical migration probabilities remain unchanged.

Spread shocks affect future values while inception prices and the base
no-migration benchmark remain fixed. This preserves the loss from spread
widening even when no issuer changes rating. Allocation cases retain total
face and calculate their own base benchmark at the unchanged market inputs.
Equal face weights change issuer risk composition as well as concentration;
a smaller face HHI does not guarantee lower ES at every confidence level.

Each case uses the same underlying normal innovations. Outputs report VaR/ES,
differences from baseline, paired mean/ES Monte Carlo errors, issuer ES
contributions, face HHI, maximum face weight and a decomposition of expected
loss into spread-shock and migration components. Only Monte Carlo uncertainty
is measured. ES intervals require both quantiles to be resolved.

The new `data/processed/credit_stress/run_.../` directory holds summary CSVs
and full-precision inputs/scenarios for every case. Exact baseline RDS files
and stress configuration are copied under `data/raw/credit_stress/run_.../`.
Old runs are preserved. See [stress methodology](docs/stress_methodology.md)
for formulas, invariants, interpretation and replay limitations.

## Validate the implementation

Run the offline checks from the project root:

```r
source("tests/test_fed_yield_curve.R")
source("tests/test_issuer_prices.R")
source("tests/test_migration_valuation.R")
source("tests/test_credit_simulation.R")
source("tests/test_credit_stress.R")
```

The synthetic fixtures cover source parsing, date cutoffs, stale and incomplete
data, percent-to-decimal conversion, continuous discounting, valid negative
rates, duplicate dates, and invalid arguments. Network availability is not
required for these tests. The issuer checks also exercise rating types and
review ages, missing rows versus missing values, unequal return intervals,
the independent Pearson formula, matrix validity, immutable snapshots and
download failures. The archive integration checks use a synthetic downloader.
Migration checks cover both public HTML layouts, exclusion of standard
deviations and later-year tables, explicit NR assumptions, rounding limits,
absorbing default, forward discounting, recovery bounds, the `PD * LGD * face`
limit, same-date market inputs, immutable valuation archives and failure cleanup.
Simulation checks include exact discrete-tail examples, binomial rank coverage,
independent two-issuer enumeration, singular dependence, probability-zero/one
states, reproducible batching, RNG restoration, same-date calibration and replay.
Stress checks verify fixed benchmarks, horizon-only pricing, PSD-preserving
correlation shocks, allocation budgets, independent shock/ES identities,
paired uncertainty and complete scenario-archive replay and cleanup.

## Repository layout

| Path | Purpose |
| --- | --- |
| `R/fed_yield_curve.R` | Reusable import and validation functions |
| `R/issuer_registry.R` | Rating categories and sourced registry validation |
| `R/issuer_prices.R` | Price import, alignment, correlation and snapshots |
| `R/transition_matrix.R` | Dated study parsing and explicit NR/default policies |
| `R/rating_spreads.R` | FRED OAS parsing and Treasury/spread date alignment |
| `R/migration_valuation.R` | Conditional values and exact marginal expectations |
| `R/migration_pipeline.R` | Input retrieval, provenance and valuation snapshots |
| `R/credit_simulation.R` | Named Gaussian dependence and batched migrations |
| `R/credit_risk_measures.R` | Discrete VaR/ES, MC uncertainty and allocations |
| `R/credit_simulation_pipeline.R` | Dated calibration and risk-run archives |
| `R/credit_stress.R` | Shock definitions, allocation and paired comparisons |
| `R/credit_stress_pipeline.R` | Baseline replay and immutable stress archives |
| `config/issuers.csv` | Reviewed issuer inputs and hypothetical portfolio design |
| `config/transition_source.csv` | Pinned study vintage and review deadline |
| `config/valuation_assumptions.csv` | Recovery, horizon and NR/spread conventions |
| `config/simulation_settings.csv` | Scenario count, seed, batching and precision |
| `config/risk_levels.csv` | Requested VaR/ES confidence levels |
| `config/stress_scenarios.csv` | Explicit dependence, pricing and allocation cases |
| `scripts/01_download_yield_curve.R` | First analysis entry point |
| `scripts/02_download_issuer_prices.R` | Second analysis entry point |
| `scripts/03_value_migrations.R` | Third analysis entry point |
| `scripts/04_simulate_credit_risk.R` | Fourth analysis entry point |
| `scripts/05_run_stress_tests.R` | Fifth analysis entry point |
| `tests/test_fed_yield_curve.R` | Offline checks using synthetic inputs |
| `tests/test_issuer_prices.R` | Offline calculations and archive integration checks |
| `tests/test_migration_valuation.R` | Offline parsing, probability and pricing checks |
| `tests/test_credit_simulation.R` | Analytical tails and simulation integration |
| `tests/test_credit_stress.R` | Pricing shocks, fixed benchmarks and paired replay |
| `docs/data_sources.md` | Sources, units, freshness policy, and limitations |
| `docs/model_methodology.md` | Equations, loss benchmarks and model assumptions |
| `docs/simulation_methodology.md` | Dependence, tail formulas and MC uncertainty |
| `docs/stress_methodology.md` | Stress conventions and comparison interpretation |
| `data/raw/` | Original source vintages, generated locally |
| `data/processed/` | Validated curves and provenance, generated locally |

See [data sources and conventions](docs/data_sources.md) for details.

## Next implementation stages

1. Build a Quarto report with assumptions, results and limitations; commit the
   reviewed renv environment and automate offline checks in GitHub Actions.
2. Compare alternative transition/dependence calibrations, more detailed credit
   term structures and empirical recovery evidence, with model-risk analysis.
