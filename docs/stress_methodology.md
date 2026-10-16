# Credit sensitivity and stress comparisons

## Objective and acceptance criteria

Identify how dependence, spread valuation, recovery and exposure allocation
change the one-year loss distribution. Compare VaR, ES, expected loss and issuer
ES contributions while preserving a selected market-data vintage and total
face budget. All monetary amounts are **USD millions**.

The baseline must reproduce the chosen stage-04 destinations and losses.
Every matrix must remain PSD, issuer ES contributions must sum to portfolio ES,
and simulated means must agree with analytical expectations within Monte Carlo
variation. Valuation-only adverse shocks on the same allocation must not
improve any paired scenario payoff. Failed checks leave no partial stress run.

This is a transparent set of deterministic sensitivities, not a calibrated
macroeconomic crisis forecast, a scenario-probability estimate or a regulatory
capital calculation. The BCBS stress-testing principles distinguish sensitivity
analysis from broader scenario analysis and emphasize explicit objectives,
assumptions, methods and documentation. This project does not claim compliance
with a bank's full stress-testing framework.

## Scenario definitions

`config/stress_scenarios.csv` contains the following defaults. It requires one
unchanged baseline first and checks that each category matches the factors
changed. The recovery entries must be reviewed if the saved baseline recovery
assumption changes.

| Case | Correlation mixture | Horizon spread change | Recovery | Allocation |
| --- | --- | --- | --- | --- |
| Baseline | 0 | 0 bps | 40% | Original |
| Correlation 50% | 0.50 | 0 bps | 40% | Original |
| Correlation 85% | 0.85 | 0 bps | 40% | Original |
| Spread +100 bps | 0 | +100 bps | 40% | Original |
| Recovery 20% | 0 | 0 bps | 20% | Original |
| Combined sensitivity | 0.50 | +100 bps | 20% | Original |
| Equal face amounts | 0 | 0 bps | 40% | Equal amounts |
| Weakest group at 50% | 0 | 0 bps | 40% | Half of total face in worst bucket |

No probability is assigned to a case. Shock sizes are chosen assumptions;
their empirical calibration is not established. The combined case captures
coincident shocks in these three factors but leaves migration probabilities
and Treasury rates unchanged. It is not a complete recession model.

## Dependence shock

For the saved correlation `C` and mixture `lambda`, use

$$C_\lambda=(1-\lambda)C+\lambda\mathbf{1}\mathbf{1}^{\mathsf T},
\qquad 0\leq\lambda\leq1.$$

Both components are PSD with unit diagonal, so their convex combination has
those properties. Every off-diagonal coefficient moves toward one. For example,
an initial correlation 0.30 becomes 0.65 when `lambda=0.50`; the label does not
mean that every correlation becomes 50% or rises by 50 percentage points.
At `lambda=1`, the supported singular matrix gives perfect latent dependence.

Physical marginal migration probabilities do not change. Consequently, the
**exact mean** of linear portfolio value cannot change from correlation alone,
although a finite simulated mean can fluctuate. Tail estimates can move.
Discrete VaR need not increase monotonically for every possible portfolio and
confidence level. Defaults are not assumed to have the same correlation as
the Gaussian latent variables.

## Horizon-only pricing and a fixed benchmark

Let `v_(i,k)^0` be the base conditional horizon values for a particular
allocation and `B_i=v_(i,k_i)^0` its base no-migration benchmark. A spread shock
`d` in basis points changes only surviving horizon values:

$$v_{i,k}^{stress}=v_{i,k}^{0}\exp[-(d/10000)(T_i-h)],\qquad k\ne D.$$

Five-year exposures have four years remaining, so +100 bps multiplies a
surviving horizon value by `exp(-0.01*4)`. Inception prices are unchanged.
The default payment is `R_stress*N_i` at the horizon, without an extra spread
discount. Recovery is fixed within each case, with no default/recovery
dependence or workout delay.

Loss uses the **fixed base** amounts:

$$L^{stress}=\sum_i(B_i-v_{i,K_i}^{stress}).$$

Recomputing the benchmark under wider spreads would remove the very repricing
loss this exercise aims to measure. The simulator accepts named fixed issuer
benchmarks and carries them into ES allocation and exact-mean calculations.
It still checks that the supplied state values and their expectations are
internally consistent with the transition matrix.

Expected loss is decomposed into

$$E[L^{stress}]=\underbrace{\sum_i(B_i-v_{i,k_i}^{stress})}
_{\text{no-migration shock loss}}+
\underbrace{\sum_i(v_{i,k_i}^{stress}-E[v_{i,K_i}^{stress}])}
_{\text{migration component under shocked valuation}}.$$

The first component captures repricing without a rating change. Neither
component is automatically floored at zero. Reduced recovery cannot lower a
paired loss, and positive spread widening cannot improve surviving payoffs,
when dependence, allocation and migration outcomes are held fixed. A spread
shock may leave an extreme all-default tail unchanged because recovery payments
do not depend on non-default spreads.

## Allocation and concentration

Every allocation preserves the total face amount. Equal-face allocation uses
`total face / issuer count`. The weakest-group case identifies the worst broad
initial rating and assigns that **whole group** half the face. It preserves
original relative weights within the group and within the remaining issuers.
At least two distinct rating groups are required; ties are not resolved by an
arbitrary first issuer.

Each different allocation has its own base no-migration benchmark at the same
unshocked market inputs. Allocation cases therefore compare different
portfolios under a shared face budget. Their inception values and benchmark
values need not be identical. The output includes both absolute losses and
losses as a percentage of face.

Face HHI is `sum(face_weight^2)`; the effective issuer count is its reciprocal.
These describe face concentration, not concentration of credit risk. Equal
face weights also change rating/issuer composition, so lower HHI alone does
not establish lower ES. The weakest group may already have more than half the
face in another portfolio; this rule is then a different allocation, not
necessarily a worsening concentration shock. Interpret the actual changes.
Issuer ES contributions reveal where portfolio-tail losses are allocated.

## Paired Monte Carlo comparisons

Each case reuses the baseline's saved scenario count, batch size, seed, RNG
algorithms and risk levels. The same independent normal innovations are
consumed by scenario row. If only valuations or face weights change, destination
states are identical. With a correlation shock, the new factor transforms the
same innovations differently. Eigenvector rotations/signs mean that variance
reduction is not guaranteed for dependence changes.

For paired losses `L_s` and `L_0`, the mean-difference standard error is
`sd(L_s-L_0)/sqrt(N)`. It accounts for the dependence between runs; treating
their errors as independent would discard that pairing.

For ES confidence `alpha`, with resolved sample quantiles `q_s` and `q_0`, use

$$D=\frac{(L_s-q_s)_+-(L_0-q_0)_+}{1-\alpha},\qquad
\widehat{SE}(\Delta ES)=sd(D)/\sqrt N.$$

The point difference is `q_s-q_0+mean(D)`. Normal paired ES intervals are
approximate and reported only when **both** component VaR rank intervals
resolve to their respective quantiles. Otherwise the interval endpoints are
missing and the approximate standard error remains labeled as such. No VaR
difference confidence interval is claimed. Component binomial VaR intervals
and discrete-tail conventions are described in
[simulation methodology](simulation_methodology.md).

These intervals address Monte Carlo sampling conditional on the cases and
inputs. They do not quantify uncertain shock severity, correlation estimates,
transition probabilities, ratings, source adjustments, spreads, recovery or
model specification. The Gaussian proxy and fixed physical transition matrix
exclude important crisis dynamics.

## Inputs, outputs and replay

Select a stage-04 directory explicitly. The workflow does not search for the
newest run or download fresh observations. A current analysis rejects a market
date more than 14 calendar days before its completed-day cutoff. A deliberately
specified historical cutoff enables replay, without establishing historical
point-in-time data availability.

The exact baseline `simulation_inputs.rds`, `scenarios.rds` and stress CSV are
copied with full MD5 fingerprints into a new raw archive. Baseline replay
checks all destination states and losses before evaluating other cases.
Differences require rebuilding stage 04 in the current R environment, rather
than comparing unmatched random experiments. MD5 identifies file content and
accidental changes; it is not a security signature.

The processed run contains:

- `stress_risk.csv`: all component VaR/ES estimates and Monte Carlo diagnostics.
- `stress_comparisons.csv`: paired differences from baseline and their errors.
- `portfolio_metrics.csv`: face concentration, benchmarks and exact loss split.
- `issuer_es_contributions.csv`: additive tail allocations for every case/level.
- `simulation_diagnostics.csv` and `stress_correlations.csv`: model checks.
- `scenario_definitions.csv`, `metadata.csv` and `stress_inputs.rds`: provenance.
- One subdirectory per case, with `case_inputs.rds` and `scenarios.rds`.

Load the R modules listed in script 05 and read a deliberately selected
`case_inputs.rds` to replay an individual case with
`simulate_credit_migrations()`. Pass its `case$valuation`, saved transition,
`case$correlation`, saved scenario controls and `case$benchmark_values`.
Retain the source commit and reviewed renv files; bitwise portability across
different R/BLAS/LAPACK implementations is not promised. Generated provider
inputs and results remain outside Git.

## Validation and primary references

Synthetic tests independently check four-year spread discounting, unchanged
inception prices/default payments, fixed-benchmark loss without migrations,
PSD mixture limits, tied weakest groups, constant budgets, paired shift
uncertainty, analytical means and discrete-tail ES enumeration. Integration
checks replay all eight case archives and reject stale, inconsistent or altered
baselines while preserving previously completed runs.

- BCBS, Stress testing principles (2018):
  https://www.bis.org/publications/201810-guidelines-stress-testing-principles
- BCBS consolidated guidelines, RMA30, Stress testing:
  https://www.bis.org/committees/bcbs/basel-consolidated-guidelines/module/rma/30
- CreditMetrics Technical Document, Gupton, Finger and Bhatia (1997):
  https://www.msci.com/documents/10199/93396227-d449-4229-9143-24a94dab122f
