# frozen_string_literal: true

require_relative "syntheticalert/version"

module Triplepat
  # A measurement callback for a synthetic alert. Filled in by later tasks.
  class SyntheticAlert
    # Default mean silent gap between firings, in seconds.
    DEFAULT_MEAN_INTERVAL = 3600.0
    # Default lower bound on the silent gap, in seconds.
    DEFAULT_MIN_INTERVAL = 600.0
    # Default upper bound on the silent gap, in seconds.
    DEFAULT_MAX_INTERVAL = 7200.0
    # Default length of each firing, in seconds.
    DEFAULT_FIRING_DURATION = 600.0
  end
end
