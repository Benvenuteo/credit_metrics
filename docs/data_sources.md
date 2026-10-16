# Data sources and conventions

## Implemented: USD base yield curve

- Provider: Federal Reserve Board.
- Dataset: Gürkaynak, Sack, and Wright (GSW) nominal Treasury yield curve.
- Documentation: https://www.federalreserve.gov/data/nominal-yield-curve.htm
- Download: https://www.federalreserve.gov/data/yield-curve-tables/feds200628.csv
- Selected source columns: `SVENY01` through `SVENY30`.
- Input units: percent per annum, continuously compounded.
- Output units: decimal annual continuously compounded rates.
- Discount factor at maturity `t`: `exp(-zero_rate_continuous * t)`.

These are fitted Treasury zero-coupon yields. They form the USD base curve;
they are not corporate rating-specific curves or credit spreads. Forward
curves and credit spreads must be introduced in the valuation stage.

The observations are daily, but the provider normally posts updated data
once per week, typically on Tuesday through the previous Friday. A download
today is therefore not evidence that today's market observation is available.
The default freshness limit is 14 calendar days, allowing two publication
cycles. This is a project policy, not a guarantee from the provider. A stale
or incomplete latest observation stops the import with an informative error.

The CSV contains a metadata preamble. The importer locates the `Date` header
and checks the stated compounding convention before interpreting its values.
Historical missing yields are preserved. Missing current yields, malformed
numbers, duplicate dates, and non-finite rates are rejected. Negative yields
are valid and are not removed as outliers.

## Provenance and repeatability

Each successful run archives:

- The original downloaded CSV under `data/raw/fed_yield_curve/`.
- A new processed snapshot directory under `data/processed/fed_yield_curve/`.
- `curve.csv`: observation date, maturities, rates, and discount factors.
- `metadata.csv`: URL, download timestamp in UTC, analysis cutoff, source
  observation date, calendar-day age, units, and the raw-file fingerprint.

Identical raw files are deduplicated by their full MD5 content fingerprint.
The fingerprint identifies a data vintage and accidental corruption; it is
not a security signature. Processed snapshots are never overwritten.
Generated data are excluded from Git; preserve selected snapshots separately
when you need to retain an analysis. Failed downloads do not silently fall
back to an older cache.

The provider may revise historical estimates. Selecting an old `as_of_date`
from a newly downloaded CSV uses the current data vintage. It does not
reconstruct what was actually available on that historical date. Point-in-time
backtesting requires previously archived vintages and their availability dates.

## Implemented: issuer register

`config/issuers.csv` is a manually reviewed input, not an automated rating feed.
It retains the original face-value allocation and a new hypothetical five-year
zero-coupon design. No actual bond identifier, market price, covenant or claim
seniority is asserted. The first public-source review is dated 2026-10-16.

| Issuer / ticker | Listing | S&P issuer notch | Broad bucket | Dated source |
| --- | --- | --- | --- | --- |
| Intel / INTC | NASDAQ, USD | BBB | BBB | 2026-04-27 |
| Amazon / AMZN | NASDAQ, USD | AA | AA | 2026-03-10 |
| NVIDIA / NVDA | NASDAQ, USD | AA | AA | 2026-08-18 |
| NetApp / NTAP | NASDAQ, USD | BBB+ | BBB | 2025-03-12 |
| Bristow / VTOL | NYSE, USD | B+ | B | 2026-01-13 |

Primary rating evidence, with issuer ratings explicitly identified:

- Intel: https://www.spglobal.com/ratings/en/regulatory/article/-/view/sourceId/101682301
- Amazon: https://www.spglobal.com/ratings/en/regulatory/article/-/view/sourceId/101673852
- NVIDIA: https://www.spglobal.com/ratings/en/regulatory/article/-/view/type/HTML/id/3613280
- NetApp: https://www.spglobal.com/ratings/en/regulatory/article/-/view/type/HTML/id/3336569
- Bristow: https://www.spglobal.com/ratings/en/regulatory/article/-/view/type/HTML/id/3501902

The source URLs sometimes describe a new debt issue, but the values selected
here are the explicitly stated long-term **issuer** ratings within those
announcements. Bristow's secured-note rating differs from its issuer rating.
Current VTOL on NYSE must not be combined with the predecessor BRS series.
Each row also links to an issuer's own investor-relations or SEC filing page
confirming the listing. Intel's outlook is left `not_recorded`; outlooks do
not enter the present calculations.

S&P public announcement excerpts and primary issuer pages support this review.
Some full rating reports require authentication. This register does not claim
authenticated, real-time status or exhaustive coverage of subsequent actions.
For NetApp, the latest explicit public issuer-rating confirmation located in
the review is from March 2025. Its old source date is deliberately preserved.
Verify status with the agency before the final risk report; obtaining a current
rating feed is a separate data-access decision if stronger guarantees are needed.

`rating_source_date` is the date of the supporting announcement, which may
confirm an existing rating. `rating_reviewed_on` records when the sources and
subsequent announcements were checked. It is not a new rating-action date.
The maximum review age is 30 calendar days, a project policy. An expired review
stops the import; the code never advances review dates itself. This control
does not make a historic announcement a guaranteed current rating.

Full S&P notches map to broad `AAA`, `AA`, `A`, `BBB`, `BB`, `B`, `CCC/C`, `D`
buckets. `SD` maps to `D`. `NR` and unknown notations are rejected, rather than
being ordered below default. The transition-matrix stage still has to specify
and validate the treatment of withdrawn ratings and the default state.

## Implemented: daily equity prices

- Provider: Yahoo Finance, obtained through `quantmod::getSymbols(src="yahoo")`.
- Adapter documentation: https://www.quantmod.com/documentation/getSymbols.yahoo.html
- Package source and current releases: https://github.com/joshuaulrich/quantmod
- Human-readable source pages: `https://finance.yahoo.com/quote/<ticker>/history/`.
- Frequency: daily; currency and exchange are the reviewed listing configuration.
- Columns retained: Open, High, Low, Close, Volume, Adjusted.
- Return input: the provider's `Adjusted` series, without a second adjustment.
- Return definition: `log(Adjusted[t] / Adjusted[previous source row])`.

This educational portfolio uses a publicly accessible source without a service
level guarantee. There is no automatic fallback to another provider, cached
prices, or the Close column. A provider/API failure stops the run. Network
requests have finite connection and download timeouts. Generated market data
are kept locally and not redistributed in the repository.

The quantmod documentation records historical Yahoo adjustment and missing-data
issues. Accordingly, the pipeline does not present this series as an independently
certified total-return index. Inspect the saved Close/Adjusted prices and flagged
moves around splits, dividends and other corporate actions. No custom dividend
reinvestment or split adjustment is layered on top of the provider's Adjusted
column. A different or independently validated adjustment source would require
a documented policy change and comparison of results.

The default cutoff is yesterday in `America/New_York`, even if today's session
has already closed. The current session is always excluded. Three calendar
years of prices are requested through that cutoff. Source rows outside the
window cannot enter the calculations. The latest Close and Adjusted value must
both be present; an incomplete latest row does not cause a silent fallback to
an earlier row. Source age and the final common-return age may not exceed
seven calendar days. Weekends and holidays naturally produce no daily row.

Dates must be valid and unique within issuer. Non-missing prices must be finite
and positive; non-missing volume must be finite and non-negative. Historical
missing values remain visible and are not interpolated. Absolute log returns
greater than 0.35 are flagged in `outliers.csv`; none are automatically deleted
or winsorized. This is a review threshold, not an economic plausibility bound.

## Implemented: common returns and correlation

Calculate returns within each issuer's original dated series before joining
dates. A return enters the final matrix only if all issuers have a finite return
with the same start date and end date. For example, a missing Tuesday row at one
issuer cannot pair its Monday-to-Wednesday return with another issuer's
Tuesday-to-Wednesday return. An explicit missing Adjusted value also invalidates
the following return. Prices are never filled to manufacture an observation.

Candidate end dates are the union of source return dates. Coverage is the
number of retained common intervals divided by the number of candidates.
Defaults require at least 500 observations and 95% common coverage. Every
excluded candidate remains in `sample_audit.csv`. These controls use the source
calendar: a session omitted by every issuer cannot be detected from their union
alone. They do not replace an independent exchange-calendar reconciliation.

All Pearson correlations use exactly the same complete sample, avoiding
inconsistent pairwise samples. Constant return series are rejected. Validate
finite entries, symmetry, unit diagonal, bounds and a minimum eigenvalue of
at least `-1e-8`. No nearest-positive-definite repair is applied silently.
A singular positive-semidefinite matrix is accepted; the later simulation
algorithm must support it or make any regularization choice explicit.

Equity-return correlation is a modeling proxy for issuer dependence. It does
not directly measure latent asset or default correlation. Sensitivity to the
estimation window, proxy choice and correlation stress remains part of the
model-validation stage. Do not annualize the correlation coefficients.

## Issuer snapshot provenance

Every successful run retains:

- `data/raw/issuer_prices/run_.../source_exports.rds`: original returned quantmod
  objects, before this project's filtering and transformations; not raw HTTP JSON.
- `data/raw/issuer_prices/run_.../issuers.csv`: exact source-registry bytes.
- A corresponding immutable `data/processed/issuer_prices/run_.../` directory.
- `prices.csv`, `returns.csv`, `correlation.csv`, `quality.csv`, `sample_audit.csv`
  and `outliers.csv`, including an empty outlier table when no moves were flagged.
- `issuer_registry.csv` and `sources.csv`: parsed inputs and provider source pages.
- `metadata.csv`: download time in UTC, cutoffs, adjustment policy, common sample,
  thresholds, matrix eigenvalue, package/R versions, and full MD5 fingerprints
  of the registry and source export. MD5 is an identity/corruption check, not a
  security signature. Equity source exports are retained per run without deduplication.

Historical price adjustments can change in future downloads. An earlier cutoff
on the current vintage is not a historical point-in-time dataset. The current
rating register also cannot establish past ratings. The importer rejects a
cutoff before its supporting rating announcements; passing that check still
does not establish historical information availability. True backtests require
archived vintages and dated rating histories.

Fed and equity sources have different publication schedules. Their individual
observation dates remain explicit. The valuation stage below aligns Treasury
and OAS dates; the equity sample still needs to be aligned to that market date
when introducing correlated simulation.

## Implemented: dated transition matrix

- S&P Global Ratings, 2025 Annual Global Corporate Default And Rating
  Transition Study, published 2026-03-18.
- Source URL and manual update policy: `config/transition_source.csv`.
- Selected table: 21, global corporate average transitions, 1981–2025,
  **one-year** block. The later-year blocks and parenthesized standard
  deviations are excluded.
- Input units: percentages. Preserve the NR column in the published-input
  archive; choose and audit an explicit modeling policy when removing it.
- Default is an added absorbing model row. Source percentages are normalized
  only within a maximum 0.05 percentage-point rounding discrepancy.

The source is a long-run historical pool from the latest pinned annual study,
not an estimate from 2025 alone or a next-year forecast. The HTML is downloaded
afresh for each valuation run, but the study vintage is deliberately pinned.
Check for a newer annual study before its configured review deadline. Both
source title and date coverage are validated during parsing. Original source
bytes remain local; provider probability observations are not bundled in Git.

## Implemented: rating-index spread proxies

Provider: ICE Data Indices, LLC, distributed by FRED. Source units are **percent**,
daily close, not seasonally adjusted. Individual source pages are
`https://fred.stlouisfed.org/series/<series_id>`.

| Broad bucket | FRED series ID |
| --- | --- |
| AAA | `BAMLC0A1CAAA` |
| AA | `BAMLC0A2CAA` |
| A | `BAMLC0A3CA` |
| BBB | `BAMLC0A4CBBB` |
| BB | `BAMLH0A1HYBB` |
| B | `BAMLH0A2HYB` |
| CCC/C proxy | `BAMLH0A3HYC` |

Retrieval uses `https://fred.stlouisfed.org/graph/fredgraph.csv` with explicit
series IDs and a requested date window. The code applies its own cutoff because
the returned multi-series history can extend beyond the requested range.
Missing historical values remain missing. An all-missing calendar row is not
an observation; a partially missing latest observed row stops the import.
FRED notes that these ICE series have limited rolling history from April 2026.
They cannot supply unrestricted historical vintages for backtests.

OAS measures index spreads relative to a Treasury spot curve. Here, percent
observations divided by 100 approximate additive continuous credit spreads,
held flat across maturity and frozen at the future horizon. This is a stated
model approximation, not an exact conversion or a bootstrapped zero curve.
Index ratings and composition do not identify the five actual issuers' credit
curves. Do not substitute effective index yields for spreads or add default
as another yield category.

Index observations are subject to the provider's reuse terms documented on the
FRED source pages. Generated source/processed observations remain untracked;
tests and committed example observations are synthetic. Public report data
selection must account for those terms.

## Implemented: explicit recovery assumption and valuation snapshots

The baseline fixed recovery is 40% of face paid at the one-year horizon, with
20% and 60% comparisons. This is an assumption recorded in
`config/valuation_assumptions.csv`, not a newly measured recovery rate or an
assertion about actual issue seniority. It is separate from every yield/spread
column. NR handling is also explicit and compared under two policies.

Each valuation run retains raw S&P HTML, raw FRED CSV, exact copies of the three
configuration files and a reference to the archived Fed vintage. Processed
outputs include published and modeled transition tables, rounding/NR audits,
conditional state values, exact expected values, sensitivity results, same-date
market inputs and source fingerprints. `model_inputs.rds` preserves full
precision for later simulation. Failed runs remove their partial valuation
snapshot, while previously successful independent Fed imports remain valid.

See [model methodology](model_methodology.md) for forward discounting, benchmark
definitions and the treatment of publication lags. Correlated simulation,
tail-risk validation and a portfolio report remain subsequent work. More
detailed credit term structures and empirical recovery calibration are further
model improvements.
