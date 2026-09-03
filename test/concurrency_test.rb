# frozen_string_literal: true

require "test_helper"

class ConcurrencyTest < Minitest::Test
  THREADS = 8
  TEN_DAYS = 10 * 24 * 3600.0
  MAX = Triplepat::SyntheticAlert::DEFAULT_MAX_INTERVAL
  FIRING = Triplepat::SyntheticAlert::DEFAULT_FIRING_DURATION

  # Eight threads race to replay the same long pause and must all observe one
  # state. With the GVL this checks consistency rather than detecting data
  # races, which is the most Ruby can offer without test-only lock machinery.
  def test_concurrent_scrapes_agree
    clock = FakeClock.new
    alert = Triplepat::SyntheticAlert.new(clock: clock)
    clock.advance(TEN_DAYS)

    observed = scrape_from_threads(alert)

    assert_equal 1, observed.uniq.size, "every thread must observe the same state: #{observed}"
    assert_includes [0.0, 1.0], observed.first
    next_transition = alert.instance_variable_get(:@next_transition)

    assert_operator next_transition, :>, clock.now
    assert_operator next_transition, :<=, clock.now + MAX + FIRING
  end

  private

  # Release THREADS threads together, each scraping once; returns their values.
  def scrape_from_threads(alert)
    starting_gun = Queue.new
    threads = Array.new(THREADS) do
      Thread.new do
        starting_gun.pop
        alert.value
      end
    end
    THREADS.times { starting_gun << :go }
    threads.map(&:value)
  end
end
