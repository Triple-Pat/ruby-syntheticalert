# frozen_string_literal: true

require_relative "lib/triplepat/syntheticalert/version"

Gem::Specification.new do |spec|
  spec.name = "triplepat-syntheticalert"
  spec.version = Triplepat::SyntheticAlert::VERSION
  spec.authors = ["Triple Pat"]
  spec.summary = "A synthetic alert measurement callback, so a Triple Pat check-in timer " \
                 "can verify your alerting pipeline end to end."
  spec.description = "Provides a time-based callback to drive a synthetic alert metric. " \
                     "Register it as a gauge, alert on the gauge, and route the alert to a " \
                     "Triple Pat check-in timer; if the check-ins stop, your alerting is broken."
  spec.homepage = "https://triplepat.com"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/Triple-Pat/ruby-syntheticalert",
    "bug_tracker_uri" => "https://github.com/Triple-Pat/ruby-syntheticalert/issues",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir.glob("lib/**/*.rb", base: __dir__) + %w[LICENSE README.md]
  spec.require_paths = ["lib"]
end
