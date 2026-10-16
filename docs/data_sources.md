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

## Planned sources

The following inputs remain separate work items: issuer ratings, equity prices
and their adjustment policy, estimated issuer correlations, the latest
appropriate S&P rating transition matrix, rating-specific credit spreads,
and documented recovery assumptions. The current importer supplies the
Treasury base curve only.
