# One-year migration valuation

## Problem and acceptance criteria

Estimate how rating migration and default change the one-year value of the
configured hypothetical zero-coupon portfolio. Face amounts and all monetary
outputs are in **USD millions**. The five-year maturity starts at the selected
market observation date; these are new hypothetical exposures, not bonds
originally bought in 2023.

The implementation must preserve probability mass, distinguish default from
withdrawal, value the correct remaining maturity, separate carry from migration
loss, and retain dated source evidence. Tests check independent pricing
identities and the zero-rate `PD * LGD * face` limit. The implemented
[simulation stage](simulation_methodology.md) adds dependence and tail risk.

## Data and common market date

The Fed GSW Treasury curve supplies continuous zero rates. ICE BofA rating-index
OAS series are obtained through FRED. The seven index labels are mapped to the
seven non-default broad rating buckets; the CCC & Lower index is a proxy for
the model's CCC/C group. Index labels/composition are not issuer-specific S&P
zero-coupon curves.

The requested cutoff excludes the current New York calendar day. The latest
Fed observation may be up to 14 calendar days old because of its publication
schedule. The independently checked latest OAS feed may be up to seven days old.
Valuation then uses the latest date observed in **both** histories, at most
14 days before the requested cutoff. Every Treasury tenor and rating spread
must be present on that date. A partial latest shared row causes an error;
neither source is filled or carried forward to manufacture a common date.

For example, a requested cutoff of 2026-10-15 can have a latest Fed observation
of 2026-10-09 and a latest OAS observation of 2026-10-15. Both valuation inputs
then use **2026-10-09**, which remains explicit in the output metadata. This
does not assert that October 15 prices were used. The equity-correlation sample
is aligned to the selected valuation date in the simulation stage.

## Historical migration probabilities

The pinned source is S&P's 2025 annual global corporate study, published
2026-03-18. Select the one-year block of table 21 for 1981–2025. It is a
long-run historical transition estimate, not a forecast of next year's
issuer-specific default probabilities. The geographic/sector pool is broader
than this portfolio; a U.S./nonfinancial or stressed calibration is a future
comparison.

Extract the mean percentages, excluding the parenthesized standard deviations
and the three-, five- and seven-year blocks. Small row-sum discrepancies of
at most 0.05 percentage points are normalized and audited. Larger errors stop
the calculation. The ordered model states are:

`AAA, AA, A, BBB, BB, B, CCC/C, D`.

The study's NR column records an unobserved/withdrawn rating outcome. It is
not placed below default. Two explicit assumptions are compared:

| Policy | Calculation for a published row | Interpretation |
| --- | --- | --- |
| `condition_on_observed` (baseline) | Divide the eight observed-state weights by their sum | Estimate conditional on an observed rating/default outcome; changes PD and assumes the missing outcomes can be ignored for this conditional model |
| `nr_to_initial_rating` | Normalize all nine published weights, then assign NR mass to the starting grade | Impute no rating change for unobserved outcomes; preserves normalized default mass |

Neither policy recovers the unknown outcomes. `transition_audit.csv` shows
published totals, rounding error, NR mass and the change in PD. Default is an
added absorbing row, with probability one of remaining in D. Published zero
probabilities remain zero; no unreported floor or smoothing is introduced.

## Valuation equations

Let `N_i` be face amount, `T_i` initial maturity, `h = 1` the risk horizon,
`z_0(t)` a continuous Treasury zero rate and `s_k` a rating spread proxy.

Inception value at the initial rating `k_i`:

$$V_{0,i}=N_i\exp[-(z_0(T_i)+s_{k_i})T_i].$$

The Treasury forward rate for the remaining life follows from the ratio of
discount factors, rather than an assumption that the four-year spot rate is
the one-year forward rate:

$$f_0(h,T_i)=\frac{T_i z_0(T_i)-h z_0(h)}{T_i-h}.$$

For a non-default horizon rating `k`:

$$V_{h,i,k}=N_i\exp[-(f_0(h,T_i)+s_k)(T_i-h)].$$

Five years at inception therefore become **four remaining years**, not a
single discounting period. Required Treasury tenors must exist exactly;
interpolation/extrapolation is not implicit. Only the annual horizon is
supported by this stage's one-year matrix.

The baseline treats `index OAS percent / 100` as an additive continuous spread
**approximation**, flat across maturity and frozen at the horizon. This is not
an exact compounding conversion or a bootstrapped corporate zero curve. Index
maturity, sector, liquidity and optionality effects limit its interpretation.
The source spreads are not reordered or forced to be monotonic; the metadata
records whether their broad-rating order is monotonic.

The stress stage optionally adds `horizon_spread_shock_bps / 10000` to every
non-default horizon spread. It leaves inception spreads/prices unchanged and
does not discount the horizon default payment. Its fixed base benchmark is
separate from the no-migration value under shocked spreads; see
[stress methodology](stress_methodology.md).

For default:

$$V_{h,i,D}=R N_i.$$

The baseline `R = 0.40` is a chosen fixed recovery assumption. It is not a
current empirical estimate or a claim about these companies' actual debt
seniority. Payment occurs at the risk horizon; the model does not simulate
default timing, workout delay or recovery reinvestment. Compare 20%, 40% and
60% recovery in the sensitivity output. Bounds zero and one are valid. Future
stochastic recovery and dependence between default and recovery need their
own evidence and tests.

## What the reported values mean

Historical physical probabilities `p_(k_i,k)` give the exact marginal mean:

$$E[V_{h,i}]=\sum_k p_{k_i,k}V_{h,i,k},\qquad
E[V_h]=\sum_i E[V_{h,i}].$$

The mean does not require an issuer-correlation assumption because expectation
is linear. It is not an arbitrage-free price obtained by risk-neutral
calibration. Forward Treasury rates are a deterministic valuation convention,
not a forecast of realized future interest rates.

| Output | Definition |
| --- | --- |
| Initial value | `V_0`, the model's current discounted portfolio value |
| No-migration horizon value | Sum of `V_(h,i,k_i)`; a benchmark, not an expectation |
| Expected horizon value | Probability-weighted sum across every destination, including D |
| Expected credit loss | No-migration horizon value minus expected horizon value; includes migration effects |
| Expected total P&L | Expected horizon value minus initial value; includes carry and credit effects |
| Expected loss versus risk-free roll | `V_0 * exp(h*z_0(h)) - E[V_h]` |

Different benchmarks answer different questions. Gains and negative benchmark
losses are retained. Nothing is clipped to zero. In a zero-rate/zero-spread
default-only limit, expected credit loss reduces to `PD * (1-R) * N`.
Portfolio VaR and Expected Shortfall are supplied separately by correlated
simulation; these exact means serve as its analytical validation benchmark.

## Sources and reproducibility

- CreditMetrics Technical Document, Gupton, Finger and Bhatia (1997),
  particularly horizon valuation of remaining cash flows:
  https://www.msci.com/documents/10199/93396227-d449-4229-9143-24a94dab122f
- S&P annual study and current pinned descriptor:
  https://www.spglobal.com/ratings/en/regulatory/article/default-transition-and-recovery-2025-annual-global-corporate-default-and-rating-transition-study-s101673333
- FRED series notes and index definitions, with individual IDs retained in output:
  https://fred.stlouisfed.org/series/BAMLC0A2CAA
  and https://fred.stlouisfed.org/series/BAMLH0A3HYC

Raw HTTP responses, the exact configuration copies and input fingerprints stay
in the local run archive. `model_inputs.rds` preserves validated matrices,
dates and numeric precision for the next stage. Provider data are not included
in Git; committed examples and test observations are synthetic. Review provider
reuse terms before including their index observations in a public report.

These are current downloaded vintages with dated manual rating reviews. They
do not establish what information was available historically. The study review
deadline is a project update policy, not a promise of the next publication date.
Updating annual sources requires reviewing the new study and changing its
descriptor; a fresh download alone does not update a pinned vintage.
