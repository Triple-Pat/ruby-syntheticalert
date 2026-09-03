# frozen_string_literal: true

require "test_helper"

class ScheduleTest < Minitest::Test
  include ScheduleInvariants

  EPSILON = 1e-6
  # Every cycle is one silent gap plus one firing, so ten days holds this many cycles.
  FEWEST_CYCLES = (TEN_DAYS / (MAX + FIRING)).floor
  MOST_CYCLES = (TEN_DAYS / (MIN + FIRING)).floor + 1

  def setup
    @clock = FakeClock.new
    @alert = Triplepat::SyntheticAlert.new(clock: @clock)
  end

  def next_transition
    @alert.instance_variable_get(:@next_transition)
  end

  def test_starts_resolved
    assert_in_delta 0.0, @alert.value
  end

  def test_fires_exactly_at_the_end_of_the_gap
    first_firing = next_transition
    @clock.now = first_firing - EPSILON

    assert_in_delta 0.0, @alert.value, 0.0, "firing just before the gap elapsed"

    @clock.now = first_firing

    assert_in_delta 1.0, @alert.value, 0.0, "not firing at the end of the gap"
    assert_in_delta first_firing + FIRING, next_transition
  end

  def test_resolves_exactly_after_the_firing_duration
    @clock.now = next_transition
    @alert.value # firing
    resolved_at = next_transition
    @clock.now = resolved_at - EPSILON

    assert_in_delta 1.0, @alert.value, 0.0, "resolved before the firing duration elapsed"

    @clock.now = resolved_at

    assert_in_delta 0.0, @alert.value, 0.0, "still firing after the firing duration"
  end

  def test_gap_is_measured_from_end_of_firing
    @clock.now = next_transition
    @alert.value # firing
    resolved_at = next_transition
    @clock.now = resolved_at
    @alert.value # resolved; a fresh gap was drawn from here

    assert_operator next_transition, :>=, resolved_at + MIN
    assert_operator next_transition, :<=, resolved_at + MAX
  end

  def test_value_is_always_zero_or_one
    100.times do
      @clock.advance(1_000.0)

      assert_includes [0.0, 1.0], @alert.value
    end
  end

  def test_long_pause_replays_every_transition
    draws = record_gap_draws(@alert)
    @clock.advance(TEN_DAYS)
    value = @alert.value

    assert_includes [0.0, 1.0], value
    assert_schedule_is_one_transition_ahead(@alert, @clock)
    assert_operator draws.size, :>=, FEWEST_CYCLES, "one gap per replayed cycle"
    assert_operator draws.size, :<=, MOST_CYCLES, "one gap per replayed cycle"
  end

  private

  # Wrap the private gap sampler so each drawn gap is recorded; one draw per
  # replayed cycle. Returns the array the draws land in.
  def record_gap_draws(alert)
    draws = []
    real_gap = alert.method(:gap)
    alert.define_singleton_method(:gap) do
      draws << real_gap.call
      draws.last
    end
    draws
  end
end
