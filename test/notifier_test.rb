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
end
