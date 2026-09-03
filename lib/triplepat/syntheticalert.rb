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

    # All durations are numbers of seconds and are stored as Floats. +clock+
    # returns the current time in seconds and must never go backwards; it
    # exists for tests.
    #
    # Raises ArgumentError if any duration is not a positive, finite number, the
    # firing duration is not shorter than the mean interval, or the min and
    # max intervals do not bracket the mean. Setting all three intervals
    # equal is allowed: the window has zero width, every gap is exactly that
    # long, and the schedule becomes periodic, which is pointless in
    # production but handy for deterministic debugging.
    def initialize(mean_interval: DEFAULT_MEAN_INTERVAL, min_interval: DEFAULT_MIN_INTERVAL,
                   max_interval: DEFAULT_MAX_INTERVAL, firing_duration: DEFAULT_FIRING_DURATION,
                   clock: MONOTONIC_CLOCK)
      @mean = duration("mean interval", mean_interval)
      @min = duration("min interval", min_interval)
      @max = duration("max interval", max_interval)
      @firing_duration = duration("firing duration", firing_duration)
      check_ordering(@mean, @min, @max, @firing_duration)
      @clock = clock
      @lock = Mutex.new
      @firing = false
      @next_transition = clock.call + gap
    end

    # Returns 1.0 if the synthetic alert should be firing right now and 0.0
    # otherwise. Replays every schedule transition between the last call and
    # now, so the realized schedule is the same whatever the scrape cadence.
    def value
      # Why carry state and replay transitions, rather than compute the state
      # from the clock alone?
      #
      # A stateless answer to "is a firing in progress?" needs the firing times
      # to be a pure function of wall-clock time. That is possible for a plain
      # Poisson process, because it has independent increments: chop time into
      # epochs, seed a PRNG from the epoch index, draw that epoch's arrivals,
      # and check whether one falls within the last firing duration. It has a
      # real attraction, too: every replica of a service would compute the
      # same schedule and raise one alert instead of N.
      #
      # But the min and max bounds on the silent gap make each gap depend on
      # where the previous firing ended, which destroys independent increments;
      # epochs can no longer be generated in isolation. Thinning and
      # back-filling a plain Poisson stream to fake the bounds would have to
      # peek across epoch boundaries and would no longer have a distribution
      # the tests can name. The bounds exist for practical reasons (the alert
      # must visibly resolve; the check-in timer must not false-alarm), so we
      # honor them exactly with an alternating renewal process: fixed firings,
      # i.i.d. truncated-exponential gaps, and a few words of state.
      #
      # Replaying every missed transition, rather than jumping to the current
      # state, keeps the realized schedule identical whatever the scrape
      # cadence. It costs one loop iteration per elapsed transition, about
      # fifty a day at the defaults, so even a scrape after a week of silence
      # is trivial.
      @lock.synchronize do
        now = @clock.call
        while now >= @next_transition
          @firing = !@firing
          @next_transition += @firing ? @firing_duration : gap
        end
        @firing ? 1.0 : 0.0
      end
    end

    private

    # Returns the duration as a Float so the sampler's divisions are never
    # Integer floor divisions, which would silently distort the distribution.
    def duration(name, value)
      unless value.is_a?(Numeric) && value.real?
        raise ArgumentError,
              "#{name} must be a real number, got #{value.inspect}"
      end

      value = value.to_f
      # NaN compares false to everything, so it needs the explicit finite? check.
      raise ArgumentError, "#{name} must be positive and finite, got #{value}" unless value.finite? && value.positive?

      value
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
      # in [0, 1), so 1.0 - rand is in (0, 1] and u lands in [s_max, s_min].
      # Math.log never sees 0 because u is strictly positive either way: when
      # s_max > 0 that is immediate, and when s_max underflowed to 0 the draw
      # is (1.0 - rand) * s_min, at least 2^-53 * e^-1.
      s_max = Math.exp(-@max / @mean)
      s_min = Math.exp(-@min / @mean)
      u = s_max + ((1.0 - rand) * (s_min - s_max))
      # Mathematically the draw is already in [@min, @max]: this is not
      # clamping a distribution, it corrects the few ulps by which exp followed
      # by log can miss a round trip, so the bounds hold literally rather than
      # to within floating-point rounding.
      (-@mean * Math.log(u)).clamp(@min, @max)
    end
  end
end
