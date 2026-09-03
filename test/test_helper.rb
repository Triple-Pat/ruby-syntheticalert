# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  cover "lib/**/*.rb"
  # Bundler evaluates the gemspec, which requires version.rb, before this
  # file runs, so those three lines can never register a hit.
  skip "lib/triplepat/syntheticalert/version.rb"
  # CI adds the gate; keeping it out of local runs lets partial runs pass.
  if ENV["CI"]
    coverage :line, minimum: 100
    coverage :branch, minimum: 100
  end
end

require "triplepat/syntheticalert"
require "minitest/autorun"

# A clock that only moves when told to.
class FakeClock
  attr_accessor :now

  def initialize(now = 1_000.0)
    @now = now
  end

  def call
    @now
  end

  def advance(seconds)
    @now += seconds
  end
end

# Invariants shared by the schedule and concurrency tests.
module ScheduleInvariants
  FIRING = Triplepat::SyntheticAlert::DEFAULT_FIRING_DURATION
  MIN = Triplepat::SyntheticAlert::DEFAULT_MIN_INTERVAL
  MAX = Triplepat::SyntheticAlert::DEFAULT_MAX_INTERVAL
  TEN_DAYS = 10 * 24 * 3600.0

  # After any scrape the next transition lies in the future and at most one
  # cycle, a max gap plus a firing, away.
  def assert_schedule_is_one_transition_ahead(alert, clock)
    next_transition = alert.instance_variable_get(:@next_transition)

    assert_operator next_transition, :>, clock.now
    assert_operator next_transition, :<=, clock.now + MAX + FIRING
  end
end
