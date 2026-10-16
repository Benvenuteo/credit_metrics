# VaR exceptions: exact binomial tails and Kupiec coverage

## Implemented code versus empirical evidence

`R/var_backtesting.R` implements the exception-count test described in the
original project discussion and the Kupiec unconditional-coverage LR test.
The implementation is checked with synthetic counts and dated fixtures.
**Neither those tests nor simulated destination frequencies constitute a
realized-loss backtest of the CreditMetrics portfolio.** No empirical pass/fail
result is reported when dated forecast/outcome pairs are absent.

The current portfolio contains hypothetical zero-coupon claims and has a
one-year risk horizon. Daily equity returns calibrate a dependence proxy;
they are not realized losses on those claims. An honest historical test needs
dated exposures, forecasts using only information available at each origin,
future valuations/default outcomes and a consistent loss benchmark.

## Exact exception-count test

Let `alpha` be VaR confidence, `N` the number of evaluated non-overlapping
periods and `m` the number of strict exceptions `realized_loss > forecast_VaR`.
Under iid exceptions with constant probability `p0=1-alpha`, use

$$M\sim Binomial(N,p_0),$$

$$p_{lower}=\sum_{k=0}^{m}{N\choose k}p_0^k(1-p_0)^{N-k},\qquad
p_{upper}=\sum_{k=m}^{N}{N\choose k}p_0^k(1-p_0)^{N-k}.$$

Both sums include the observed count. In R, calculate the upper tail as
`pbinom(m-1, N, p0, lower.tail=FALSE)`. Using `m` there incorrectly computes
`P(M>m)` and excludes its probability mass.

The requested rule does not reject when **both probabilities exceed 0.05**.
It consists of two one-sided tests at 5%, giving central rejection size at
most 10%. For a central size at most 5%, use 2.5% per tail. Discreteness can
make the actual size smaller than these bounds. The code and report retain
both conventions rather than silently substituting one for the other.
Clopper–Pearson rate intervals use the corresponding central confidence.

```r
# Synthetic count example only; not a backtest result for this portfolio.
source("R/credit_simulation.R")
source("R/credit_risk_measures.R")
source("R/var_backtesting.R")
test_var_exception_count(250, 3, confidence_level = 0.99,
                         tail_significance = 0.05)
test_var_exception_count(250, 3, confidence_level = 0.99,
                         tail_significance = 0.025)
```

## Kupiec unconditional coverage

For `p_hat=m/N`, the statistic compares the fixed-null binomial likelihood
with its maximized likelihood:

$$LR_{uc}=2\{\log L(\widehat p)-\log L(p_0)\}.$$

The combinatorial factors cancel. Using log probabilities from `dbinom()`
handles zero exceptions and all exceptions without evaluating `0*log(0)`.
The p-value uses the asymptotic chi-square distribution with one degree of
freedom and a separate default 5% significance. Its finite-sample behavior
can be poor for sparse exceptions. A non-rejection is not proof of accuracy.
Kupiec coverage does not test independence, clustering or loss severity beyond
VaR. Christoffersen tests and dedicated ES backtests are not implemented here.

## Dated input contract

Copy `config/var_backtest_template.csv` to an explicit data path and supply
documented observations. The empty template deliberately contains no results.
`read_credit_var_backtest(path, evaluation_date)` validates:

| Field | Meaning |
| --- | --- |
| `portfolio_id` | One consistently defined portfolio/forecast series |
| `forecast_date` | Forecast origin and start of the evaluated period |
| `horizon_end_date` | Annual contractual endpoint, 365 or 366 days later |
| `estimation_end_date` | No later than forecast origin |
| `estimation_window_size` | Declared number of estimation observations, at least two |
| `var_usd_million` | Signed loss quantile from that forecast origin |
| `realized_loss_usd_million` | Later signed loss on corresponding exposures |
| `confidence_level` | Constant target within each tested confidence group |
| `forecast_benchmark` | Must be `no_migration_horizon` |
| `realized_benchmark` | Must match the forecast benchmark |
| `outcome_type` | `observed_portfolio_loss`, `historical_revaluation_proxy` or `synthetic_example` |
| `loss_source` | Evidence and valuation/market-day convention for the outcome |

Period dates describe the annual contractual horizon; document business-day
marking adjustments in the source field. Forecast/realized units must both be
USD millions. Gains may be negative. Equality at VaR is audited separately and
does not count as a strict exception. Missing, malformed or non-finite input
is rejected, not imputed. Different confidence levels may share forecast dates;
periods must not overlap within a confidence group.

The adapter evaluates supplied forecasts. It does not generate a rolling
forecast series, reconstruct estimation windows from the declared count,
independently verify provenance or recover point-in-time rating histories.
Changing only a date or using today's study to forecast the past would not
establish a valid historical experiment. Non-overlap is necessary for the
simple iid binomial interpretation but does not establish independence.

## Discrete quantiles and power

For a loss distribution with atoms and inverse-CDF VaR `q_alpha`,
`P(L>q_alpha) <= 1-alpha`. Equality need not hold. Thus a coverage-equality test
can reject a conservative but valid discrete quantile for too few exceptions.
The code reports the requested nominal tests and ties explicitly; it does not
claim their equality null is automatically correct for CreditMetrics.
Distributional calibration respecting boundary mass, or an explicit model
strict-exceedance target, needs further design before empirical interpretation.

A million Monte Carlo scenarios are not a million historical forecast periods.
At VaR 99%, 20 independent annual outcomes imply only 0.2 expected exceptions.
A short annual sample provides little evidence about a remote tail. Daily
overlapping annual outcomes cannot be inserted into the ordinary binomial test
as independent observations to manufacture sample size.

## Report integration

Stage 06 defaults to `backtest_file=NULL` and displays **not performed**.
An explicitly supplied CSV is archived, fingerprinted and tested with both
central-tail conventions and Kupiec. Synthetic examples are labeled as
demonstrations, and historical revaluation proxies retain that designation.
The evaluation cutoff is separate from the original simulation date, allowing
later realized outcomes to be tested when they actually become available.
No input label alone certifies model validity or source authenticity.

Primary references:

- Kupiec (1995), Techniques for Verifying the Accuracy of Risk Measurement Models:
  https://fraser.stlouisfed.org/title/1491/item/717921
- Cassidy and Gizycki (1997), RBA RDP 9708, section 3:
  https://www.rba.gov.au/publications/rdp/1997/9708/backtesting.html
- R binomial distribution functions:
  https://stat.ethz.ch/R-manual/R-devel/library/stats/html/Binomial.html
