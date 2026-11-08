# frozen_string_literal: true

require "test_helper"

require "fileutils"

ENV["RAILS_ENV"] = "test"

require_relative "../fixtures/rails/config/application"

Rails.application.initialize!

require "active_record/fixtures"
require "action_dispatch/system_test_case"
require "capybara/cuprite"

require "rackup"

require "rackup/handler/raptor"
require "raptor/embedded"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :messages do |table|
    table.string :body, null: false
  end
end

rails_server = nil
rails_server_thread = nil
Capybara.register_server :raptor do |app, port, host|
  rails_server_thread = Thread.current
  Rackup::Handler::Raptor.run(app, Host: host, Port: port, Workers: 0, Threads: 3, MaxThreads: 3) do |server|
    rails_server = server
  end
end
Capybara.server = :raptor
Capybara.server_host = "127.0.0.1"
Capybara.app = Rails.application

Minitest.after_run do
  begin
    Capybara.current_session.driver.quit if rails_server
  ensure
    begin
      rails_server&.shutdown
      rails_server&.join
      rails_server_thread&.value
    ensure
      ActiveRecord::Base.connection_handler.clear_all_connections!
      FileUtils.remove_entry(Rails.application.config.x.database_directory)
    end
  end
end

module Raptor
  class TestIntegrationRails < ActionDispatch::SystemTestCase
    include ActiveRecord::TestFixtures

    driven_by :cuprite, options: {
      headless: true,
      process_timeout: 20,
      browser_options: { "no-sandbox" => nil }
    }

    def setup
      super
      assert_equal 0, Message.count
    end

    def test_browser_reads_a_record_in_the_rails_test_transaction
      assert_transaction_visible_in_browser("Uncommitted first message")
    end

    def test_another_transaction_starts_empty_and_is_visible_in_the_browser
      visit "/"
      assert_no_selector "li"

      assert_transaction_visible_in_browser("Uncommitted second message")
      assert_no_text "Uncommitted first message"
    end

    private

    def assert_transaction_visible_in_browser(body)
      assert_predicate Message.connection, :transaction_open?
      Message.create!(body: body)

      database = ActiveRecord::Base.connection_db_config.database
      SQLite3::Database.open(database) do |connection|
        assert_equal 0, connection.get_first_value("SELECT COUNT(*) FROM messages")
      end

      visit "/"

      assert_selector "li", text: body, exact_text: true
      assert_selector "main[data-process-id='#{Process.pid}']" \
        "[data-application-id='#{Rails.application.object_id}']"
    end
  end
end
