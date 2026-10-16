# Correlated migrations and portfolio tail risk

## Scope and calibration date

The risk horizon is one year. Stage 04 takes a deliberately selected stage-03
snapshot, retaining its physical transition matrix, hypothetical exposures,
conditional horizon values, fixed recovery and flat spread approximations.
It recalibrates equity-return dependence through the same market observation
date as the Treasury/OAS valuation. All monetary quantities are **USD millions**.

Three calendar years of current-vintage Yahoo Adjusted prices are requested.
Log returns are calculated before joining dates, requiring common interval
endpoints, at least 500 complete observations and 95% common coverage. The
last common return must end exactly on the valuation date. Missing observations
are not filled and flagged extreme returns are retained. These are proxies
subject to the source/adjustment limitations in [data sources](data_sources.md).

## Gaussian migration model

For each scenario draw independent standard normal innovations and construct

$$Z\sim N(0,C),$$

where `C` is the named common-sample equity-return correlation matrix. It is
used as a **latent asset dependence proxy**, not an observed default correlation.
Correlation coefficients are not annualized. The model does not estimate a
continuous asset-return process or default times within the year.

The transition source stores states from best to worst. For mapping, reverse
each issuer's initial-rating row to `D, CCC/C, B, BB, BBB, A, AA, AAA`, exclude
zero-probability destinations and form cumulative probabilities. Boundaries are

$$b_{i,j}=\Phi^{-1}\left(\sum_{k=1}^{j}p_{i,k}\right).$$

Intervals are open on the left and closed on the right. Lower latent outcomes
therefore select default/downgrades; high outcomes select better ratings.
The boundaries use theoretical transition probabilities, never quantiles of
the simulated draws. The marginal distribution is preserved in probability;
sample frequencies fluctuate naturally rather than being forced to match.

An eigenvalue factor supports singular positive-semidefinite matrices.
Eigenvalues below `-1e-8` cause an error. Tiny negative values in `[-1e-8,0)`
are clipped as roundoff, factor rows are rescaled to unit variance, and both
the clip count and largest correlation reconstruction change are recorded.
No substantive nearest-positive-definite correction is silently applied.

## Loss benchmark and exact mean

For issuer `i`, let `v_(i,k)` be its stage-03 horizon value in destination `k`,
and `k_i` its initial rating. For simulated destinations `K_i`, define

$$L_i=v_{i,k_i}-v_{i,K_i},\qquad L=\sum_i L_i.$$

Positive losses reduce value relative to the **no-migration horizon benchmark**.
Upgrades can produce negative losses; these are retained. This differs from
loss relative to current value or a risk-free rolled investment. The saved
metadata identifies the benchmark so that carry is not mistaken for credit loss.
An optional named `benchmark_values` argument supports fixed base benchmarks
in stress cases. The simulator retains these issuer amounts, and ES allocation
uses them consistently. The baseline default remains the no-migration horizon
value from the supplied valuation.

The exact mean is available without simulation:

$$\mu_L=\sum_i\left(v_{i,k_i}-\sum_k p_{i,k}v_{i,k}\right).$$

The run reports its sample mean, `sd(L)/sqrt(N)`, a normal Monte Carlo interval
and the standardized difference from this exact mean. A six-standard-error
review flag is diagnostic, not an identity that every finite sample must pass.
Marginal destination counts have binomial standard-error diagnostics. The
simulated **latent** correlation is compared with the matrix actually used;
default-indicator correlation is not expected to equal that matrix.

## VaR and Expected Shortfall with atoms

For confidence `alpha`, the empirical VaR is the inverse empirical CDF:

$$\widehat q_\alpha=\inf\{x:\widehat F_N(x)\geq\alpha\}.$$

The implementation uses `stats::quantile(type = 1)`. It does not interpolate
between distinct portfolio outcomes. Expected Shortfall is the tail quantile
integral, calculated as

$$\widehat{ES}_\alpha=\widehat q_\alpha+
\frac{1}{N(1-\alpha)}\sum_{s=1}^{N}(L_s-\widehat q_\alpha)_+.$$

This matters because a rating model has a discrete distribution with large
atoms. Averaging only losses strictly greater than VaR can give the wrong ES.
Let `m=N*(1-alpha)`, `a` count losses above VaR and `b` count losses equal to it.
Every above-VaR scenario receives weight `1/m`; each tied scenario receives
`(m-a)/(b*m)`. Other scenarios receive zero. The weights sum to one, including
when `m` is fractional. No zero floor is applied to VaR or ES.

For example, losses `0,2,2,2,10` at confidence 50% have VaR 2 and ES 5.2.
The worst 2.5 scenarios comprise the loss of 10 and half of each tied loss of 2.
The conditional mean strictly above VaR would incorrectly give 10.

Issuer ES contributions apply these **same portfolio-tail weights** to each
issuer's signed loss. They sum to portfolio ES, including boundary atoms.
This is a symmetric conditional allocation of the empirical tail; it does not
assert a unique differential Euler allocation at a nondifferentiable atom.
Contributions and shares can be negative when an issuer offsets other losses.
Shares are undefined if portfolio ES is zero. Additional outputs subtract the
exact mean from VaR/ES and the exact issuer mean from each ES contribution.

## Monte Carlo precision

Defaults use `N=1,000,000`, seed 20261016, batches of 50,000 and confidence
levels 95%, 99%, 99.9%. The nominal smallest tail is 1,000 scenarios. The
configuration rejects smaller nominal tails than the chosen policy threshold.
Atom weights, effective tail composition and sampling variation still matter;
one million scenarios is not a universal accuracy guarantee.

For a Monte Carlo coverage `1-delta`, VaR intervals invert binomial ranks:

$$l=Q_{Bin(N,\alpha)}(\delta/2),\qquad
u=Q_{Bin(N,\alpha)}(1-\delta/2)+1.$$

The interval uses ordered losses `[L_(l), L_(u)]`. At ranks zero or `N+1`,
it uses known theoretical loss-support bounds, not the observed extremes.
Without known bounds the corresponding endpoint is infinite. These intervals
are conservative when the model distribution has atoms. A zero-width interval
means the discrete quantile is resolved at that Monte Carlo coverage; it does
not imply absence of model uncertainty.

With a locally stable quantile, the excess-payoff approximation is

$$\widehat{SE}(\widehat{ES}_\alpha)=
\frac{sd((L-\widehat q_\alpha)_+)}{(1-\alpha)\sqrt N}.$$

The normal ES interval is reported only when both finite VaR interval
endpoints equal the estimated VaR. Otherwise its endpoints are `NA`; the
standard error remains explicitly labeled approximate. This is not an exact
finite-sample ES confidence procedure or a bootstrap. Normal approximations
can be poor for sparse extreme excesses even when the quantile is resolved.

All intervals describe **iid Monte Carlo error conditional on the selected
model and inputs**. They exclude uncertainty in transition estimation,
correlation calibration, ratings, recovery, spreads, source revisions and model
specification. Gaussian dependence does not capture non-Gaussian joint tail
behavior. The implemented [stress comparisons](stress_methodology.md) vary the
equity dependence proxy and fixed recovery alongside spreads and allocation.

Convergence outputs use nested prefixes of 10,000, 50,000, 100,000, 500,000 and
the full sample, removing duplicates or checkpoints above `N`. They are
dependent diagnostics, not independent repeated experiments. Inspect both
point estimates and their Monte Carlo uncertainty before claiming precision.

## Replay and implementation checks

The RNG algorithms are explicitly Mersenne-Twister/Inversion/Rejection. Draws
are consumed by scenario row, preserving the sequence when the batch size
changes. The caller's RNG kind and seed, including the absence of a seed, are
restored after success or failure. Batching bounds continuous latent memory;
losses and integer destination states remain available for exact tail auditing.

Each run saves input/config fingerprints, dated calibration returns, original
and used matrices, seed/settings, R/platform/LAPACK versions, and numeric RDS
inputs/scenarios. No directory is selected implicitly as the newest. To replay,
source the R modules used by script 04, read a deliberately chosen
`simulation_inputs.rds`, recompute `value_migration_states()` from
`valuation_inputs`, and call `simulate_credit_migrations()` with the saved
correlation, scenario count, batch size and seed. This requires no new market
download. Retain the corresponding source commit and reviewed renv lockfile;
bitwise results across different R/BLAS/LAPACK implementations are not promised.

Offline tests independently enumerate a zero-rate two-issuer example with
default probabilities 10% and 20%, zero recovery and unit faces. Independent
defaults give mean loss 0.3, joint default probability 0.02, VaR(95%) 1 and
ES(95%) 1.4. Tests also cover perfect positive/negative dependence, singular
matrices, default/upgrade ordering, zero/one probabilities, atom weights,
binomial coverage, issuer allocation, RNG restoration, batching, date alignment,
archive replay, stale inputs and cleanup after failures. Fixtures are synthetic.

## Primary references

- Gupton, Finger and Bhatia, CreditMetrics Technical Document (1997):
  https://www.msci.com/documents/10199/93396227-d449-4229-9143-24a94dab122f
- Acerbi and Tasche, On the coherence of Expected Shortfall (2001/2002),
  discussing definitions in distributions with discontinuities:
  https://arxiv.org/abs/cond-mat/0104295
- R quantile documentation, type 1 inverse empirical distribution:
  https://stat.ethz.ch/R-manual/R-devel/library/stats/html/quantile.html
- R binomial distribution and quantile functions:
  https://stat.ethz.ch/R-manual/R-devel/library/stats/html/Binomial.html
