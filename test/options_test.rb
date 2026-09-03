# frozen_string_literal: true

require "test_helper"

class OptionsTest < Minitest::Test
  def test_defaults_are_applied
    alert = Triplepat::SyntheticAlert.new

    assert_in_delta 3600.0, alert.instance_variable_get(:@mean)
    assert_in_delta 600.0, alert.instance_variable_get(:@min)
    assert_in_delta 7200.0, alert.instance_variable_get(:@max)
    assert_in_delta 600.0, alert.instance_variable_get(:@firing_duration)
  end

  def test_default_constants_match_the_siblings
    assert_in_delta 3600.0, Triplepat::SyntheticAlert::DEFAULT_MEAN_INTERVAL
    assert_in_delta 600.0, Triplepat::SyntheticAlert::DEFAULT_MIN_INTERVAL
    assert_in_delta 7200.0, Triplepat::SyntheticAlert::DEFAULT_MAX_INTERVAL
    assert_in_delta 600.0, Triplepat::SyntheticAlert::DEFAULT_FIRING_DURATION
  end

  BAD_DURATIONS = [0.0, -1.0, Float::NAN, Float::INFINITY].freeze

  def test_each_duration_must_be_positive_and_finite
    %i[mean_interval min_interval max_interval firing_duration].each do |name|
      BAD_DURATIONS.each do |bad|
        error = assert_raises(ArgumentError, "#{name}=#{bad}") do
          Triplepat::SyntheticAlert.new(**{ name => bad })
        end
        assert_match(/positive and finite/, error.message)
      end
    end
  end

  def test_firing_duration_must_be_shorter_than_the_mean
    error = assert_raises(ArgumentError) do
      Triplepat::SyntheticAlert.new(mean_interval: 60.0, firing_duration: 60.0, min_interval: 60.0)
    end
    assert_match(/firing duration/, error.message)
  end

  def test_min_and_max_must_bracket_the_mean
    error = assert_raises(ArgumentError) do
      Triplepat::SyntheticAlert.new(min_interval: 3601.0)
    end
    assert_match(/bracket/, error.message)
    error = assert_raises(ArgumentError) do
      Triplepat::SyntheticAlert.new(max_interval: 3599.0)
    end
    assert_match(/bracket/, error.message)
  end

  def test_equal_min_mean_max_is_allowed
    alert = Triplepat::SyntheticAlert.new(
      mean_interval: 60.0, min_interval: 60.0, max_interval: 60.0, firing_duration: 10.0,
    )

    assert_in_delta 60.0, alert.instance_variable_get(:@min)
  end

  def test_starts_resolved_with_a_transition_one_gap_ahead
    now = 1_000.0
    alert = Triplepat::SyntheticAlert.new(clock: -> { now })

    refute alert.instance_variable_get(:@firing)
    next_transition = alert.instance_variable_get(:@next_transition)

    assert_operator next_transition, :>=, now + 600.0
    assert_operator next_transition, :<=, now + 7200.0
  end
end
