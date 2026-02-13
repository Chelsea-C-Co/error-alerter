require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    ErrorAlerter.reset!
  end

  def teardown
    ErrorAlerter.reset!
  end

  def test_defaults
    config = ErrorAlerter.configuration
    assert_nil config.webhook_url
    assert_equal 300, config.dedup_ttl
    assert_equal 5, config.max_backtrace_lines
    assert_equal 500, config.max_error_length
    assert_nil config.app_name
    assert_nil config.redis
  end

  def test_enabled_when_url_set
    ErrorAlerter.configure { |c| c.webhook_url = "https://hooks.slack.com/test" }
    assert ErrorAlerter.configuration.enabled?
  end

  def test_disabled_when_url_blank
    ErrorAlerter.configure { |c| c.webhook_url = "" }
    refute ErrorAlerter.configuration.enabled?
  end

  def test_disabled_when_url_nil
    refute ErrorAlerter.configuration.enabled?
  end

  def test_configure_block
    ErrorAlerter.configure do |c|
      c.webhook_url = "https://hooks.slack.com/test"
      c.dedup_ttl = 600
      c.app_name = "TestApp"
    end

    config = ErrorAlerter.configuration
    assert_equal "https://hooks.slack.com/test", config.webhook_url
    assert_equal 600, config.dedup_ttl
    assert_equal "TestApp", config.app_name
  end

  def test_reset_clears_configuration
    ErrorAlerter.configure { |c| c.webhook_url = "https://hooks.slack.com/test" }
    ErrorAlerter.reset!
    assert_nil ErrorAlerter.configuration.webhook_url
  end
end
