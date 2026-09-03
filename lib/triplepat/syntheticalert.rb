# frozen_string_literal: true

require_relative "syntheticalert/version"

module Triplepat
  # A measurement callback for a synthetic alert.
  #
  # A broken alerting pipeline looks exactly like a healthy system. +value+ is
  # 1.0 while a synthetic alert should be firing and 0.0 otherwise, on a
  # memoryless schedule. Hand it to your metrics client as a gauge value,
  # alert on the gauge, and route the alert to a Triple Pat check-in timer
  # (https://triplepat.com); every delivered alert becomes a check-in, and the
  # timer raises an alarm if the alerts stop arriving.
  #
  # Each firing holds the value at 1 for exactly +firing_duration+ seconds.
  # The silent gap between firings, from the end of one to the start of the
  # next, is exponentially distributed (memoryless) with mean +mean_interval+:
  # an attempt at a Poisson process, which cannot synchronize with cron jobs
  # or scrape cycles. As a nod to practicality the gap is truncated to
  # [+min_interval+, +max_interval+], which makes the process only roughly
  # Poisson; widen the bounds to get closer.
  #
  # The schedule advances lazily: nothing happens until +value+ is called, at
  # which point every transition up to +clock.call+ is replayed. Calls are
  # serialized with a mutex, so one object is safe to scrape from several
  # threads.
  #
  # The library owns no metric, starts no thread, and has no dependencies.
  class SyntheticAlert
    # Default mean silent gap between firings, in seconds.
    DEFAULT_MEAN_INTERVAL = 3600.0
    # Default lower bound on the silent gap, in seconds.
    DEFAULT_MIN_INTERVAL = 600.0
    # Default upper bound on the silent gap, in seconds.
    DEFAULT_MAX_INTERVAL = 7200.0
    # Default length of each firing, in seconds.
    DEFAULT_FIRING_DURATION = 600.0

    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    private_constant :MONOTONIC_CLOCK

    # All durations are Floats in seconds. +clock+ returns the current time in
    # seconds and must never go backwards; it exists for tests.
    #
    # Raises ArgumentError if any duration is not positive and finite, the
    # firing duration is not shorter than the mean interval, or the min and
    # max intervals do not bracket the mean. Setting all three intervals
    # equal is allowed: the window has zero width, every gap is exactly that
    # long, and the schedule becomes periodic, which is pointless in
    # production but handy for deterministic debugging.
    def initialize(mean_interval: DEFAULT_MEAN_INTERVAL, min_interval: DEFAULT_MIN_INTERVAL,
                   max_interval: DEFAULT_MAX_INTERVAL, firing_duration: DEFAULT_FIRING_DURATION,
                   clock: MONOTONIC_CLOCK)
      validate(mean_interval, min_interval, max_interval, firing_duration)
      @mean = mean_interval
      @min = min_interval
      @max = max_interval
      @firing_duration = firing_duration
      @clock = clock
      @lock = Mutex.new
      @firing = false
      @next_transition = clock.call + gap
    end

    private

    def validate(mean, min, max, firing)
      check_positive_and_finite("mean interval", mean)
      check_positive_and_finite("min interval", min)
      check_positive_and_finite("max interval", max)
      check_positive_and_finite("firing duration", firing)
      check_ordering(mean, min, max, firing)
    end

    def check_ordering(mean, min, max, firing)
      if firing >= mean
        raise ArgumentError,
              "firing duration (#{firing}) must be less than the mean interval (#{mean})"
      end
      return if mean.between?(min, max)

      raise ArgumentError,
            "min interval (#{min}) and max interval (#{max}) must bracket the mean interval (#{mean})"
    end

    def check_positive_and_finite(name, value)
      # NaN compares false to everything, so it needs the explicit finite? check.
      return if value.finite? && value.positive?

      raise ArgumentError, "#{name} must be positive and finite, got #{value}"
    end

    # Draw one silent gap from the exponential distribution with mean @mean,
    # truncated to [@min, @max], by inverse-CDF sampling: pick a uniform point
    # within the probability mass the exponential puts on the window, then map
    # it back through the exponential's quantile function. One draw, exact
    # shape, and the bounds hold literally.
    #
    # This is deliberately bespoke and single-use, per the series philosophy of
    # reimplementing the memoryless sampler in each library.
    def gap
      # Work with the survival function S(x) = exp(-x / mean), which is strictly
      # positive at @min (@min <= @mean, so the exponent is at least -1) but
      # underflows to exactly 0.0 when @max is hundreds of means away. rand is
      # in [0, 1), so 1.0 - rand is in (0, 1] and u lands in (s_max, s_min]:
      # never equal to s_max, so Math.log never sees 0.
      s_max = Math.exp(-@max / @mean)
      s_min = Math.exp(-@min / @mean)
      u = s_max + ((1.0 - rand) * (s_min - s_max))
      # Mathematically the draw is already in [@min, @max): this is not
      # clamping a distribution, it corrects the few ulps by which exp followed
      # by log can miss a round trip, so the bounds hold literally rather than
      # to within floating-point rounding.
      (-@mean * Math.log(u)).clamp(@min, @max)
    end
  end
end
