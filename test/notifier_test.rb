require "test_helper"
require "ostruct"

class NotifierTest < Minitest::Test
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

  def test_notify_returns_false_when_disabled
    ErrorAlerter.configure { |c| c.webhook_url = nil }
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "something broke"
    )
    assert_equal false, notifier.notify!
  end

  def test_build_payload_worker_header
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "something broke",
      queue: "default"
    )
    payload = notifier.send(:build_payload)
    assert_equal "Worker Failed", payload[:blocks][0][:text][:text]

    fields = payload[:blocks][1][:fields]
    source_field = fields.find { |f| f[:text].include?("Source") }
    assert_includes source_field[:text], "TestWorker"

    queue_field = fields.find { |f| f[:text].include?("Queue") }
    assert_includes queue_field[:text], "default"
  end

  def test_build_payload_with_app_name
    ErrorAlerter.configure { |c| c.app_name = "MyApp" }
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "broke"
    )
    payload = notifier.send(:build_payload)
    assert_equal "MyApp: Worker Failed", payload[:blocks][0][:text][:text]
  end

  def test_from_controller_builds_controller_header
    controller = OpenStruct.new(
      class: OpenStruct.new(name: "Webhooks::TransactionsController"),
      action_name: "create"
    )
    error = RuntimeError.new("controller error")
    error.set_backtrace(["#{Dir.pwd}/app/controllers/test.rb:10:in `create'"])

    notifier = ErrorAlerter::Notifier.from_controller(controller: controller, error: error)
    payload = notifier.send(:build_payload)

    assert_equal "Controller Failed", payload[:blocks][0][:text][:text]

    source_field = payload[:blocks][1][:fields].find { |f| f[:text].include?("Source") }
    assert_includes source_field[:text], "Webhooks::TransactionsController#create"

    queue_field = payload[:blocks][1][:fields].find { |f| f[:text].include?("Queue") }
    assert_nil queue_field
  end

  def test_deduplication_prevents_duplicate_notifications
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      n1 = ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "dedup test"
      )
      assert n1.notify!

      n2 = ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "dedup test"
      )
      assert_equal false, n2.notify!
    end

    assert_equal 1, posted.length
  end

  def test_different_errors_not_deduplicated
    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "error one"
      ).notify!

      ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "error two"
      ).notify!
    end

    assert_equal 2, posted.length
  end

  def test_dedup_skipped_when_no_redis
    ErrorAlerter.configure { |c| c.redis = nil }

    posted = []
    fake_client = Object.new
    fake_client.define_singleton_method(:post) { |p| posted << p; true }

    ErrorAlerter::SlackClient.stub :new, fake_client do
      ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "no redis"
      ).notify!

      # Without redis, no dedup — both should send
      ErrorAlerter::Notifier.new(
        worker_class: "TestWorker",
        error_class: "RuntimeError",
        error_message: "no redis"
      ).notify!
    end

    assert_equal 2, posted.length
  end

  def test_backtrace_included_when_provided
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "broke",
      backtrace: [
        "#{Dir.pwd}/app/workers/test_worker.rb:10:in `perform'",
        "/usr/lib/ruby/gems/sidekiq-7.0/lib/sidekiq/processor.rb:200:in `execute_job'",
        "#{Dir.pwd}/app/services/some_service.rb:25:in `call'"
      ]
    )
    payload = notifier.send(:build_payload)
    bt_block = payload[:blocks].find { |b| b.dig(:text, :text)&.include?("Backtrace") }

    assert bt_block, "expected backtrace block"
    assert_includes bt_block[:text][:text], "app/workers/test_worker.rb:10"
    assert_includes bt_block[:text][:text], "app/services/some_service.rb:25"
    refute_includes bt_block[:text][:text], "sidekiq"
  end

  def test_backtrace_omitted_when_nil
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "no trace"
    )
    payload = notifier.send(:build_payload)
    bt_block = payload[:blocks].find { |b| b.dig(:text, :text)&.include?("Backtrace") }
    assert_nil bt_block
  end

  def test_backtrace_capped_at_max_lines
    lines = 10.times.map { |i| "#{Dir.pwd}/app/services/service_#{i}.rb:#{i}:in `method'" }
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "deep",
      backtrace: lines
    )
    payload = notifier.send(:build_payload)
    bt_block = payload[:blocks].find { |b| b.dig(:text, :text)&.include?("Backtrace") }

    assert bt_block
    trace_lines = bt_block[:text][:text].scan(/app\/services\/service_\d+\.rb/).length
    assert_equal 5, trace_lines
  end

  def test_truncates_long_error_messages
    notifier = ErrorAlerter::Notifier.new(
      worker_class: "TestWorker",
      error_class: "RuntimeError",
      error_message: "x" * 1000
    )
    payload = notifier.send(:build_payload)
    msg_block = payload[:blocks].find { |b| b.dig(:text, :text)&.include?("Message") }
    assert msg_block[:text][:text].length < 600
  end

  def test_from_exception_convenience
    error = RuntimeError.new("boom")
    error.set_backtrace(["#{Dir.pwd}/app/test.rb:1"])

    notifier = ErrorAlerter::Notifier.from_exception(error, context: { source: "Rake", source_detail: "backfill:run" })
    payload = notifier.send(:build_payload)

    assert_equal "Rake Failed", payload[:blocks][0][:text][:text]
    source_field = payload[:blocks][1][:fields].find { |f| f[:text].include?("Source") }
    assert_includes source_field[:text], "backfill:run"
  end

  # --- Dedup: default flat behavior unchanged [sc-493] ---

  def test_dedup_suppresses_repeat_within_window
    assert_equal false, build_notifier.send(:deduplicated?), "first occurrence alerts"
    assert_equal true,  build_notifier.send(:deduplicated?), "repeat is suppressed"
  end

  def test_default_payload_has_no_attachments_or_count
    payload = build_notifier.send(:build_payload)
    assert_equal ":rotating_light:", payload[:icon_emoji]
    assert payload.key?(:blocks)
    refute payload.key?(:attachments)
  end

  # --- Severity (opt-in) [sc-493] ---

  def test_severity_renders_colored_attachment_and_emoji
    ErrorAlerter.configure { |c| c.severity_classifier = ->(klass, _src, _msg) { klass == "Timeout::Error" ? :transient : :critical } }

    crit = build_notifier(error_class: "RuntimeError").send(:build_payload)
    assert_equal ":rotating_light:", crit[:icon_emoji]
    assert_equal "#E01E5A", crit[:attachments][0][:color]
    refute crit.key?(:blocks)

    trans = build_notifier(error_class: "Timeout::Error").send(:build_payload)
    assert_equal ":large_blue_circle:", trans[:icon_emoji]
    assert_equal "#36C5F0", trans[:attachments][0][:color]
  end

  def test_critical_mention_prepended_only_for_critical
    ErrorAlerter.configure do |c|
      c.severity_classifier = ->(klass, _s, _m) { klass == "FatalError" ? :critical : :warning }
      c.critical_mention = "<!here>"
    end

    crit_blocks = build_notifier(error_class: "FatalError").send(:build_blocks)
    assert_equal "<!here>", crit_blocks[0][:text][:text]

    warn_blocks = build_notifier(error_class: "RuntimeError").send(:build_blocks)
    assert_equal "header", warn_blocks[0][:type], "non-critical alerts are not prefixed with the mention"
  end

  def test_bad_severity_value_falls_back_to_warning
    ErrorAlerter.configure { |c| c.severity_classifier = ->(*) { :nonsense } }
    assert_equal :warning, build_notifier.send(:severity)
  end

  # --- Burst/backoff dedup (opt-in) [sc-493] ---

  def test_backoff_counts_suppressed_occurrences_in_next_alert
    ErrorAlerter.configure { |c| c.backoff_schedule = [300, 900] }
    redis = ErrorAlerter.configuration.redis

    assert_equal false, build_notifier.send(:deduplicated?) # alert 1
    assert_equal true,  build_notifier.send(:deduplicated?) # suppressed (+1)
    assert_equal true,  build_notifier.send(:deduplicated?) # suppressed (+1)

    # Simulate the suppression window expiring, then the next alert reports the suppressed count.
    fp = build_notifier.send(:fingerprint)
    redis.store.delete("error_alerter:#{fp}")
    n = build_notifier
    assert_equal false, n.send(:deduplicated?)
    assert_equal 2, n.instance_variable_get(:@suppressed_count)
    ctx = n.send(:build_blocks).find { |b| b[:type] == "context" }
    assert_includes ctx[:elements][0][:text], "2 more occurrence"
  end

  def test_suppression_ttl_escalates_with_tier
    ErrorAlerter.configure { |c| c.backoff_schedule = [300, 900, 3600] }
    n = build_notifier
    redis = ErrorAlerter.configuration.redis
    assert_equal 300,  n.send(:suppression_ttl, redis)
    assert_equal 900,  n.send(:suppression_ttl, redis)
    assert_equal 3600, n.send(:suppression_ttl, redis)
    assert_equal 3600, n.send(:suppression_ttl, redis), "clamps at the last entry"
  end

  private

  def build_notifier(error_class: "RuntimeError", error_message: "boom")
    ErrorAlerter::Notifier.new(worker_class: "TestWorker", error_class: error_class, error_message: error_message)
  end
end
