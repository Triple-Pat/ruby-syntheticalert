# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  cover "lib/**/*.rb"
  skip "test"
  # CI adds the gate; keeping it out of local runs lets partial runs pass.
  if ENV["CI"]
    coverage :line, minimum: 100
    coverage :branch, minimum: 100
  end
end

require "triplepat/syntheticalert"
require "minitest/autorun"
