# frozen_string_literal: true

require "tmpdir"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"

module RaptorRails
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "raptor-rails-system-test-secret"
    config.logger = Logger.new(File::NULL)
    config.hosts = ["127.0.0.1"]
    config.x.database_directory = Dir.mktmpdir("raptor-rails-")
  end
end
