# frozen_string_literal: true

require "test_helper"

class ConcurrencyTest < Minitest::Test
  include ScheduleInvariants

  THREADS = 8

  # Eight threads race to replay the same long pause and must all observe one
  # state. The GVL alone would make the replay loop look atomic, so the gap
  # sampler under test yields to other threads on every draw: without the
  # mutex in value, threads then interleave inside the loop, toggle @firing
  # against stale transitions, and disagree.
  def test_concurrent_scrapes_agree
    clock = FakeClock.new
    alert = Triplepat::SyntheticAlert.new(clock: clock)
    yield_on_every_gap(alert)
    clock.advance(TEN_DAYS)

    observed = scrape_from_threads(alert)

    assert_equal 1, observed.uniq.size, "every thread must observe the same state: #{observed}"
    assert_includes [0.0, 1.0], observed.first
    assert_schedule_is_one_transition_ahead(alert, clock)
  end

  private

  def yield_on_every_gap(alert)
    real_gap = alert.method(:gap)
    alert.define_singleton_method(:gap) do
      Thread.pass
      real_gap.call
    end
  end

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
