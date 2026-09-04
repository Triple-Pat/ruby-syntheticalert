# frozen_string_literal: true

require "minitest/test_task"
require "rubocop/rake_task"

Minitest::TestTask.create
RuboCop::RakeTask.new

namespace :coverage do
  desc "Fail unless the last test run reached 100% line and branch coverage"
  task :check do
    require "json"

    result = JSON.parse(File.read("coverage/.last_run.json")).fetch("result")
    short = result.reject { |_, percent| percent >= 100 }
    abort "coverage below 100%: #{short}" unless short.empty?
    puts "coverage: #{result}"
  end
end

task default: %i[rubocop test coverage:check]
