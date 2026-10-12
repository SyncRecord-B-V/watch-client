require "test_helper"

class ForkTest < Minitest::Test
  include WatchTestHelpers

  def setup
    skip "fork not supported" unless Process.respond_to?(:fork)
    @hub = FakeHub.new
    configure_for(@hub)
  end

  def teardown
    WatchClient.reset!
    @hub&.stop
  end

  # Puma workers and Sidekiq fork after boot: the child must start its own
  # delivery thread and must not resend the parent's buffered lines.
  def test_child_process_delivers_its_own_lines
    WatchClient.configuration.flush_interval = 60
    WatchClient.logger.info("parent line")

    pid = fork do
      WatchClient.configuration.flush_interval = 0.05
      WatchClient.logger.info("child line")
      WatchClient.flush
      exit!(0)
    end
    Process.wait(pid)

    request = @hub.next_request
    assert_equal [ "child line" ], request.entries.map { |e| e["message"] }
  end
end
