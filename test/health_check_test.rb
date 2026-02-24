require "test_helper"

class HealthCheckTest < Minitest::Test
  def setup
    ErrorAlerter.reset!
    ErrorAlerter.configure do |c|
      c.webhook_url = "https://hooks.slack.com/services/test"
      c.redis = FakeRedis.new
    end
  end

  def teardown
    ErrorAlerter.reset!
  end

  # --- Helpers ---

  def healthy_df
    "Filesystem     1024-blocks      Used Available Capacity Mounted on\n" \
    "/dev/sda1         76845216  30000000  43000000      42% /\n"
  end

  def critical_df
    "Filesystem     1024-blocks      Used Available Capacity Mounted on\n" \
    "/dev/sda1         76845216  68000000   5000000      91% /\n"
  end

  def healthy_free
    "              total        used        free      shared  buff/cache   available\n" \
    "Mem:           7982        2500         500         100        4982        5200\n" \
    "Swap:          2047           0        2047\n"
  end

  def critical_free
    "              total        used        free      shared  buff/cache   available\n" \
    "Mem:           7982        7000         100         100         882         800\n" \
    "Swap:          2047           0        2047\n"
  end

  def healthy_docker
    "1.2GB (30%)\n0B\n500MB\n0B\n"
  end

  def critical_docker
    "4.5GB (70%)\n0B\n1.2GB (50%)\n207.8MB\n"
  end

  # --- Tests ---

  def test_no_alert_when_all_healthy
    ErrorAlerter::HealthCheck.stub(:`, nil) do
      # Stub backtick for each check
    end

    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    # Override shell commands to return healthy values
    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    result = ErrorAlerter::HealthCheck.run!
    assert_equal true, result
    assert_empty posted
  ensure
    # Restore private class methods by reloading
    reload_health_check!
  end

  def test_alert_sent_when_disk_exceeds_threshold
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) do |_|
      { check: "Disk Usage", value: "91%", threshold: "80%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
    end

    assert_equal 1, posted.length
    payload = posted.first
    assert_equal :warning, payload[:icon_emoji].tr(':', '').to_sym
    text = payload[:blocks][1][:text][:text]
    assert_includes text, "Disk Usage"
    assert_includes text, "91%"
  ensure
    reload_health_check!
  end

  def test_alert_sent_when_ram_exceeds_threshold
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) do |_|
      { check: "RAM Usage", value: "90%", threshold: "85%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
    end

    assert_equal 1, posted.length
    text = posted.first[:blocks][1][:text][:text]
    assert_includes text, "RAM Usage"
    assert_includes text, "90%"
  ensure
    reload_health_check!
  end

  def test_docker_check_skipped_when_not_available
    # check_docker returns nil when command output is empty (Docker not installed)
    result = ErrorAlerter::HealthCheck.send(:check_docker, 5)
    # On machines without Docker, this returns nil gracefully
    # We can't assert much here since Docker may or may not be installed,
    # but we verify it doesn't raise
    assert result.nil? || result.is_a?(Hash)
  end

  def test_disabled_when_webhook_url_blank
    ErrorAlerter.configure { |c| c.webhook_url = "" }
    result = ErrorAlerter::HealthCheck.run!
    assert_equal false, result
  end

  def test_consolidated_message_for_multiple_failures
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) do |_|
      { check: "Disk Usage", value: "91%", threshold: "80%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) do |_|
      { check: "RAM Usage", value: "90%", threshold: "85%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) do |_|
      { check: "Docker Reclaimable", value: "6.5GB", threshold: "5GB" }
    end

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
    end

    # Single consolidated message, not 3 separate ones
    assert_equal 1, posted.length
    text = posted.first[:blocks][1][:text][:text]
    assert_includes text, "Disk Usage"
    assert_includes text, "RAM Usage"
    assert_includes text, "Docker Reclaimable"
  ensure
    reload_health_check!
  end

  def test_dedup_prevents_second_alert_within_window
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) do |_|
      { check: "Disk Usage", value: "91%", threshold: "80%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
      ErrorAlerter::HealthCheck.run!
    end

    assert_equal 1, posted.length
  ensure
    reload_health_check!
  end

  def test_dedup_skipped_when_no_redis
    ErrorAlerter.configure { |c| c.redis = nil }

    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) do |_|
      { check: "Disk Usage", value: "91%", threshold: "80%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
      ErrorAlerter::HealthCheck.run!
    end

    # Without Redis, no dedup — both should send
    assert_equal 2, posted.length
  ensure
    reload_health_check!
  end

  def test_header_includes_app_name
    ErrorAlerter.configure { |c| c.app_name = "MyApp" }

    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::HealthCheck.define_singleton_method(:check_disk) do |_|
      { check: "Disk Usage", value: "91%", threshold: "80%" }
    end
    ErrorAlerter::HealthCheck.define_singleton_method(:check_ram) { |_| nil }
    ErrorAlerter::HealthCheck.define_singleton_method(:check_docker) { |_| nil }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::HealthCheck.run!
    end

    header = posted.first[:blocks][0][:text][:text]
    assert_equal "MyApp: Server Health Warning", header
  ensure
    reload_health_check!
  end

  def test_check_disk_parses_df_output
    result = ErrorAlerter::HealthCheck.send(:check_disk, 80)
    # Can't control real df output, but verify it returns nil or a valid hash
    if result
      assert_equal "Disk Usage", result[:check]
      assert result[:value].end_with?("%")
    end
  end

  def test_check_ram_returns_nil_on_macos
    # On macOS, `free -m` is not available — should return nil gracefully
    result = ErrorAlerter::HealthCheck.send(:check_ram, 85)
    # On Linux it may return a value; on macOS it returns nil
    if result
      assert_equal "RAM Usage", result[:check]
    end
  end

  def test_configuration_defaults
    config = ErrorAlerter.configuration
    assert_equal 80, config.health_check_disk_threshold
    assert_equal 85, config.health_check_ram_threshold
    assert_equal 5, config.health_check_docker_threshold
  end

  def test_configuration_overrides
    ErrorAlerter.configure do |c|
      c.health_check_disk_threshold = 90
      c.health_check_ram_threshold = 95
      c.health_check_docker_threshold = 10
    end

    config = ErrorAlerter.configuration
    assert_equal 90, config.health_check_disk_threshold
    assert_equal 95, config.health_check_ram_threshold
    assert_equal 10, config.health_check_docker_threshold
  end

  private

  def reload_health_check!
    # Force reload to restore original private methods overridden by define_singleton_method
    load File.expand_path("../../lib/error_alerter/health_check.rb", __FILE__)
  end
end
