# frozen_string_literal: true

require "test_helper"

class DistributionTest < Minitest::Test
  N = 10_000

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
end
