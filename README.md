[![Lint and Test](https://github.com/Triple-Pat/ruby-syntheticalert/actions/workflows/ci.yml/badge.svg)](https://github.com/Triple-Pat/ruby-syntheticalert/actions/workflows/ci.yml) [![Coverage Status](https://coveralls.io/repos/github/Triple-Pat/ruby-syntheticalert/badge.svg?branch=main)](https://coveralls.io/github/Triple-Pat/ruby-syntheticalert?branch=main)

# ruby-syntheticalert

Drive a synthetic alert metric from Ruby, so a
[Triple Pat](https://triplepat.com) check-in timer can verify your alerting
pipeline end to end. Works with Prometheus and OpenTelemetry.

## Why

A broken alerting pipeline looks exactly like a healthy system. No alerts
might mean nothing is wrong, or it might mean your alerting is down, and
your alerting system is the one thing that cannot alert you about itself.

This library provides a time-based callback to drive a synthetic alert
metric. You register the callback as a gauge in your existing metrics
setup, alert on the gauge like any other metric, and route the alert to a
Triple Pat check-in timer. Every delivered alert then becomes a check-in,
and every firing is another fire drill for the whole path from metric to
notification. If the check-ins ever stop, your alerting pipeline is
broken, and the Triple Pat app raises an alarm through a separate channel
to tell you so. An example alert rule and Alertmanager route are below.

## Usage

```sh
bundle add triplepat-syntheticalert   # or: gem install triplepat-syntheticalert
```

The library has no dependencies and starts no threads. It is a single
object that answers the question "should the synthetic alert be firing
right now?", and you read its `value` whenever your metrics are scraped.

```ruby
require "triplepat/syntheticalert"

alert = Triplepat::SyntheticAlert.new
alert.value # => 1.0 while firing, 0.0 otherwise
```

Ruby has three Prometheus clients in wide use and none of them can back a
gauge with a callback directly, so each gets its own wiring below. Pick the
one you already run.

### prometheus-client

The official client has no scrape-time hook, so set the gauge from a small
Rack middleware placed ahead of the exporter. It writes the value only on
the metrics path, right before the exporter reads it:

```ruby
require "prometheus/client"
require "prometheus/middleware/exporter"
require "triplepat/syntheticalert"

alert = Triplepat::SyntheticAlert.new
gauge = Prometheus::Client.registry.gauge(
  :triplepat_synthetic_alert,
  docstring: "Set to 1 when the synthetic alert should fire and 0 otherwise. " \
             "Alert on this metric and route the alert to a Triple Pat check-in " \
             "timer to continuously test your alerting pipeline.",
)

class SyntheticAlertScrape
  METRICS_PATH = "/metrics" # the exporter default; match its path: option

  def initialize(app, gauge, alert)
    @app = app
    @gauge = gauge
    @alert = alert
  end

  def call(env)
    @gauge.set(@alert.value) if env["PATH_INFO"] == METRICS_PATH
    @app.call(env)
  end
end

use SyntheticAlertScrape, gauge, alert
use Prometheus::Middleware::Exporter
```

This is for single-process servers. In Puma or Unicorn cluster mode every
worker would have its own schedule, and no `DirectFileStore` aggregation
reconciles them: `:max` keeps a worker's stale 1 in the aggregate until
that worker happens to serve another scrape, which on a quiet server holds
the alert firing indefinitely, and `:most_recent` follows whichever worker
answered the scrape, so the alert flaps between schedules. Give the
synthetic alert one process of its own instead; the prometheus_exporter
collector below is the ready-made way to do that.

### prometheus_exporter

The exporter runs in its own process and calls each collector's `metrics`
on every scrape, so the alert lives inside a collector:

```ruby
require "prometheus_exporter/server"
require "triplepat/syntheticalert"

class SyntheticAlertCollector < PrometheusExporter::Server::TypeCollector
  def initialize
    @alert = Triplepat::SyntheticAlert.new
    @gauge = PrometheusExporter::Metric::Gauge.new(
      "triplepat_synthetic_alert",
      "Set to 1 when the synthetic alert should fire and 0 otherwise.",
    )
  end

  def type
    "synthetic_alert"
  end

  def collect(_obj)
    # Nothing is ever pushed to this collector.
  end

  def metrics
    @gauge.observe(@alert.value)
    [@gauge]
  end
end
```

Start the exporter with `bundle exec prometheus_exporter -a
synthetic_alert_collector.rb`. The alert lives in that one process however
many application workers there are, which is also the answer for
prometheus-client and Yabeda users running in cluster mode.

### Yabeda

Yabeda runs `collect` blocks on every scrape, in the worker that serves it.
Like the prometheus-client wiring, this is for single-process servers:

```ruby
require "yabeda"
require "triplepat/syntheticalert"

alert = Triplepat::SyntheticAlert.new
Yabeda.configure do
  gauge :triplepat_synthetic_alert,
        comment: "Set to 1 when the synthetic alert should fire and 0 otherwise."
  collect { Yabeda.triplepat_synthetic_alert.set({}, alert.value) }
end
```

### OpenTelemetry

The Ruby metrics SDK calls an observable gauge's callback with no arguments
and takes a bare number back. The OTel-to-Prometheus exporter turns the
dotted metric name into `triplepat_synthetic_alert`:

```ruby
meter.create_observable_gauge(
  "triplepat.synthetic.alert",
  callback: alert.method(:value),
  description: "Set to 1 when the synthetic alert should fire and 0 otherwise.",
)
```

The metrics SDK (`opentelemetry-metrics-sdk`) is still pre-1.0 and its API
can change between minor versions, so pin it.

### The schedule

Each firing holds the gauge at 1 for exactly 10 minutes. The silent gap
between firings, from the end of one to the start of the next, is
memoryless: exponentially distributed with a mean of one hour.

Memoryless gaps make the firings an attempt at a Poisson process, which
cannot synchronize with cron jobs or scrape cycles, and which by the
[PASTA theorem](https://en.wikipedia.org/wiki/Arrival_theorem#Theorem_for_arrivals_governed_by_a_Poisson_process)
sees your pipeline as it typically is rather than at some special moment.

As a nod to practicality the gap is truncated. It is never less than 10
minutes, so the alert visibly resolves between firings, and never more
than two hours, so the check-in timer can be sized. The truncation pulls
the realized mean gap down to about 49 minutes and makes the process only
roughly Poisson. If you need the PASTA property and can tolerate wider
variation in start times, set a lower min and a higher max, then size the
timer for the larger max. That recovers most of the Poisson behavior; for
the last few percent, use a mean much longer than the firing duration,
since the interval between firing starts is the firing plus the gap.

The schedule advances lazily, at scrape time, from the monotonic clock. If
nobody scrapes for a while, the next scrape replays every transition it
missed, so the process stays honest whatever your scrape interval.

There is no magic here: one line is a serviceable substitute, firing for
the first ten minutes of every hour:

```ruby
gauge.set(Time.now.min < 10 ? 1.0 : 0.0)
```

But that version fires at the top of every hour, exactly when your cron
jobs are doing something interesting. The memoryless schedule cannot
synchronize with anything, and that is the point of the library. If you
want a deterministic schedule anyway, the line above is all you need.

### Options

All durations are numbers of seconds.

| Keyword | Effect | Default |
|---|---|---|
| `mean_interval:` | Mean silent gap between firings | `3600.0` |
| `min_interval:` | Lower bound on the silent gap | `600.0` |
| `max_interval:` | Upper bound on the silent gap | `7200.0` |
| `firing_duration:` | How long each firing holds the gauge at 1 | `600.0` |
| `clock:` | Callable returning the time in seconds, for tests | monotonic clock |

The firing duration must be shorter than the mean interval, and the min and
max intervals must bracket the mean. Bad options raise `ArgumentError` at
construction. Setting all three intervals equal is allowed: every gap is
then exactly that long and the schedule is periodic, which is pointless in
production but handy for deterministic debugging.

## Alert on the metric

```yaml
groups:
  - name: synthetic
    rules:
      - alert: SyntheticAlert
        expr: triplepat_synthetic_alert == 1
        labels:
          severity: synthetic
        annotations:
          summary: Synthetic alert exercising the alerting pipeline.
```

## Route the alert to a check-in timer

Create a check-in timer at [Triple Pat](https://triplepat.com), then point
the alert at it. Prefer email delivery: mail transfer agents queue, retry,
and try every backend listed in DNS, so a check-in email is more likely to
arrive than a single webhook request to a single destination. Send to the
same timer at both the `.com` and `.net` addresses. The two domains are
served by independent DNS providers, so if one zone cannot be resolved the
other address still delivers, and extra simultaneous check-ins are
harmless. Merge this into your existing Alertmanager config (the fragment
assumes you already have a default receiver and working `smtp_*` defaults):

```yaml
route:
  routes:
    - matchers:
        - alertname="SyntheticAlert"
      receiver: triplepat
      group_wait: 0s
receivers:
  - name: triplepat
    email_configs:
      - to: YOUR-TIMER-UUID@checkin.triplepat.com
        send_resolved: false
      - to: YOUR-TIMER-UUID@checkin.triplepat.net
        send_resolved: false
```

`send_resolved: false` keeps the resolve notification from counting as an
extra check-in, so each firing checks in when it starts and not again when
it resolves.

If you cannot send email, replace the `triplepat` receiver above with this
webhook receiver instead. Alertmanager rejects a configuration that defines
the same receiver name twice:

```yaml
receivers:
  - name: triplepat
    webhook_configs:
      - url: https://triplepat.com/api/v1/checkin/YOUR-TIMER-UUID
        send_resolved: false
```

## Sizing the timer

Set the check-in timer's interval to at least
`max interval + firing duration + your alerting pipeline's latency`. With
the defaults (silent gaps of at most two hours, plus 10 minutes of
firing), a three-hour timer is comfortable.

## License

Apache-2.0. See [LICENSE](LICENSE).
