# frozen_string_literal: true

require "test_helper"

class DistributionTest < Minitest::Test
  N = 10_000
  # Kolmogorov-Smirnov critical value at alpha = 0.01 for large N.
  KS_CRITICAL = 1.628 / Math.sqrt(N)
  # Evenly spaced quantiles: a noise-free stand-in for a sample from a distribution.
  QUANTILE_GRID = Array.new(N) { |i| (i + 0.5) / N }.freeze

  DEFAULTS = {
    mean_interval: Triplepat::SyntheticAlert::DEFAULT_MEAN_INTERVAL,
    min_interval: Triplepat::SyntheticAlert::DEFAULT_MIN_INTERVAL,
    max_interval: Triplepat::SyntheticAlert::DEFAULT_MAX_INTERVAL,
  }.freeze
  # exp(-max/mean) is exactly 0.0 here, the regime survival-space sampling exists for.
  FAR_MAX = { mean_interval: 1.0, min_interval: 1.0, max_interval: 1_000_000.0, firing_duration: 0.5 }.freeze

  def test_every_gap_lies_within_bounds
    alert = Triplepat::SyntheticAlert.new(
      mean_interval: 100.0, min_interval: 50.0, max_interval: 150.0, firing_duration: 1.0,
    )
    N.times do
      gap = alert.send(:gap)

      assert_operator gap, :>=, 50.0
      assert_operator gap, :<=, 150.0
    end
  end

  def test_zero_width_window_is_periodic
    alert = Triplepat::SyntheticAlert.new(
      mean_interval: 60.0, min_interval: 60.0, max_interval: 60.0, firing_duration: 1.0,
    )

    N.times { assert_in_delta 60.0, alert.send(:gap) }
  end

  def test_gap_survives_a_max_far_beyond_the_mean
    # exp(-max/mean) goes subnormal past about 708 means and is exactly 0.0
    # beyond about 745; a CDF-space draw would hand log() a zero for the
    # largest random value. Survival-space sampling must stay finite and in
    # bounds in both regions.
    [730.0, 1_000_000.0].each do |max|
      alert = Triplepat::SyntheticAlert.new(
        mean_interval: 1.0, min_interval: 1.0, max_interval: max, firing_duration: 0.5,
      )
      N.times do
        gap = alert.send(:gap)

        assert_operator gap, :>=, 1.0, "max=#{max}"
        assert_operator gap, :<=, max, "max=#{max}"
      end
    end
  end

  # A correct sampler fails one attempt about 1% of the time by construction;
  # three attempts bring the false-failure rate to about 1e-6. The wrong
  # samplers below fail every attempt.
  def test_gaps_follow_the_truncated_exponential
    [DEFAULTS, FAR_MAX].each do |window|
      alert = Triplepat::SyntheticAlert.new(**window)
      statistics = Array.new(3) { ks_statistic(Array.new(N) { alert.send(:gap) }, **window) }
      rounded = statistics.map { |d| d.round(4) }

      assert_operator statistics.min, :<=, KS_CRITICAL,
                      "#{window}: K-S statistics #{rounded} all exceed #{KS_CRITICAL.round(4)}"
    end
  end

  def test_ks_test_rejects_a_clamped_exponential
    assert_operator ks_for { |mean, lo, hi| QUANTILE_GRID.map { |u| (-mean * Math.log(1.0 - u)).clamp(lo, hi) } },
                    :>, KS_CRITICAL
  end

  def test_ks_test_rejects_a_uniform
    assert_operator ks_for { |_mean, lo, hi| QUANTILE_GRID.map { |u| lo + (u * (hi - lo)) } }, :>, KS_CRITICAL
  end

  def test_ks_test_rejects_a_mean_off_by_a_quarter
    assert_operator ks_for { |mean, lo, hi| QUANTILE_GRID.map { |u| truncated_quantile(u, mean * 1.25, lo, hi) } },
                    :>, KS_CRITICAL
  end

  # Positive control: noise-free quantiles of the right distribution pass.
  def test_ks_test_accepts_the_right_distribution
    assert_operator ks_for { |mean, lo, hi| QUANTILE_GRID.map { |u| truncated_quantile(u, mean, lo, hi) } },
                    :<, KS_CRITICAL
  end

  private

  # The K-S statistic of samples the block builds for the default window. The
  # negative controls prove the test has teeth; the positive control proves it
  # is not simply rejecting everything.
  def ks_for
    samples = yield(*DEFAULTS.values_at(:mean_interval, :min_interval, :max_interval))
    ks_statistic(samples, **DEFAULTS)
  end

  def survival(point, mean)
    Math.exp(-point / mean)
  end

  # CDF of Exp(mean) truncated to [low, high].
  def truncated_cdf(point, mean, low, high)
    (survival(low, mean) - survival(point, mean)) / (survival(low, mean) - survival(high, mean))
  end

  # Inverse of truncated_cdf.
  def truncated_quantile(quantile, mean, low, high)
    -mean * Math.log(survival(low, mean) - (quantile * (survival(low, mean) - survival(high, mean))))
  end

  # Largest distance between the empirical CDF of the samples and the
  # truncated exponential CDF for the given window.
  def ks_statistic(samples, mean_interval:, min_interval:, max_interval:, **)
    count = samples.size.to_f
    samples.sort.each_with_index.reduce(0.0) do |distance, (point, index)|
      theoretical = truncated_cdf(point, mean_interval, min_interval, max_interval)
      [distance, (((index + 1) / count) - theoretical).abs, ((index / count) - theoretical).abs].max
    end
  end
end
