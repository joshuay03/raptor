# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rake/extensiontask"

GEMSPEC = Gem::Specification.load("raptor.gemspec")

Minitest::TestTask.create

Rake::ExtensionTask.new("raptor_http", GEMSPEC) do |ext|
  ext.lib_dir = "lib/raptor"
end

Rake::ExtensionTask.new("raptor_http2", GEMSPEC) do |ext|
  ext.lib_dir = "lib/raptor"
end

namespace :rbs do
  task :generate do
    puts
    sh "rm -rf sig && rbs-inline --opt-out --output lib && echo"
  end
end

task default: %i[clobber compile rbs:generate test]
task build: %i[clobber compile rbs:generate]
task ci: %i[clobber compile test]
