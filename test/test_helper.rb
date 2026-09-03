# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  cover "lib/**/*.rb"
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
