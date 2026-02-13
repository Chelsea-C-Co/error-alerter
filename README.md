# ErrorAlerter

Lightweight error monitoring for Rails + Sidekiq apps. Posts to Slack with Redis-based deduplication, cleaned backtraces, and Block Kit formatting.

A stepping stone before Sentry/Honeybadger — get immediate Slack alerts when things break.

## Install

```ruby
# Gemfile
gem "error_alerter", github: "Chelsea-C-Co/error-alerter"
```

## Configure

```ruby
# config/initializers/error_alerter.rb
ErrorAlerter.configure do |config|
  config.webhook_url         = ENV["SLACK_ERROR_WEBHOOK_URL"]
  config.dedup_ttl           = 300   # seconds, default: 300 (5 minutes)
  config.max_backtrace_lines = 5     # default: 5
  config.max_error_length    = 500   # default: 500
  config.app_name            = "My App"  # optional, prefixes Slack header

  # Redis for deduplication (optional — without it, every error alerts)
  # Must respond to .call("SET", key, value, "NX", "EX", ttl) — see Redis section below
  config.redis = MyRedisProxy.new
end
```

### Redis Setup

The `config.redis` object must respond to `.call(*args)` using the Redis command protocol. This means the first argument is the command name as a string (e.g., `"SET"`, `"DEL"`), followed by the command arguments.

**With Sidekiq** (recommended for apps already using Sidekiq):

Sidekiq manages its own Redis connection pool. Create a proxy that borrows a connection per-call:

```ruby
class SidekiqRedisProxy
  def call(*args)
    Sidekiq.redis { |conn| conn.call(*args) }
  end
end

ErrorAlerter.configure do |config|
  config.redis = SidekiqRedisProxy.new
  # ...
end
```

**With redis-client gem directly:**

```ruby
ErrorAlerter.configure do |config|
  config.redis = RedisClient.new(url: ENV["REDIS_URL"])
  # RedisClient already responds to .call(*args)
end
```

**Without Redis:**

Leave `config.redis` as `nil`. Deduplication is disabled and every error triggers a Slack alert. This is fine for low-traffic apps.

## Usage

### Rails Controllers

**Option A: Auto rescue_from (simple)**

Include `ErrorAlerter::RailsPlugin` in your base controller. It adds a `rescue_from StandardError` that sends a Slack alert, then **re-raises** the error so your existing error handling still works.

```ruby
class ApplicationController < ActionController::API
  include ErrorAlerter::RailsPlugin
end
```

**Option B: Custom handler (more control)**

If you need to do extra work when an error occurs (log to a database, render a custom response), write your own handler and call the notifier directly:

```ruby
class Webhooks::BaseController < ActionController::API
  rescue_from StandardError, with: :handle_unhandled_error

  private

  def handle_unhandled_error(error)
    # Your custom logging
    Rails.logger.error "[WEBHOOK] #{self.class.name}##{action_name}: #{error.class}: #{error.message}"

    # ErrorAlerter notification (wrapped in rescue so Slack outage doesn't break your response)
    begin
      ErrorAlerter::Notifier.from_controller(controller: self, error: error).notify!
    rescue => e
      Rails.logger.error "[ErrorAlerter] failed to send: #{e.class}: #{e.message}"
    end

    render json: { error: "internal_error" }, status: :internal_server_error
  end
end
```

### Sidekiq Workers

Auto-register a death handler that alerts when a job exhausts all retries:

```ruby
# config/initializers/error_alerter.rb (after configure block)
ErrorAlerter::SidekiqPlugin.install!
```

Or register manually in your Sidekiq config if you want more control:

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.death_handlers << ->(job, exception) do
    ErrorAlerter::Notifier.new(
      worker_class:  job["class"],
      job_id:        job["jid"],
      error_class:   exception.class.name,
      error_message: exception.message,
      queue:         job["queue"],
      backtrace:     exception.backtrace
    ).notify!
  rescue => e
    Rails.logger.error "[ErrorAlerter] death handler failed: #{e.class}: #{e.message}"
  end
end
```

### Manual (Rake tasks, scripts, etc.)

```ruby
begin
  do_something_risky
rescue => e
  ErrorAlerter.notify(e, context: { source: "Rake", source_detail: "backfill:run" })
end
```

## Deduplication

When Redis is configured, the same error only alerts once per `dedup_ttl` window. The dedup fingerprint is an MD5 hash of:

```
error_class + source_detail + error_message
```

So `RuntimeError` in `TransactionSyncWorker` with message `"connection refused"` is one fingerprint, and `RuntimeError` in `MemberSyncWorker` with the same message is a different fingerprint.

**Fail-open behavior:** If Redis is unavailable (connection error, timeout, etc.), the dedup check is skipped and the alert sends anyway. A warning is logged. This means you may get duplicates during Redis outages, but you'll never miss an alert.

## Backtrace Cleaning

Backtraces are filtered to only show application lines (paths containing `Rails.root` or `Dir.pwd`). Framework and gem lines are stripped. The root path prefix is removed for readability.

Raw backtrace:
```
/app/workers/test_worker.rb:10:in `perform'
/usr/lib/ruby/gems/sidekiq-7.0/lib/sidekiq/processor.rb:200:in `execute_job'
/app/services/crm_service.rb:42:in `upsert'
```

Cleaned (shown in Slack):
```
app/workers/test_worker.rb:10:in `perform'
app/services/crm_service.rb:42:in `upsert'
```

Capped at `max_backtrace_lines` (default: 5).

## Slack Message Format

Messages use Slack Block Kit with this structure:

```
[Header]  CRM Middleware: Worker Failed
[Fields]  Source: TransactionSyncWorker | Error: RuntimeError | Time: Feb 11, 2026 3:45 PM ET | Queue: default
[Section] Message: connection refused
[Section] Backtrace: app/services/crm_service.rb:42:in 'upsert'
```

- **Header** — `"{source} Failed"` (e.g., "Worker Failed", "Controller Failed", "Rake Failed"). Prefixed with `app_name` if configured.
- **Fields** — Source (worker class or controller#action), error class, timestamp, and queue (workers only).
- **Message** — Error message, truncated to `max_error_length`.
- **Backtrace** — Cleaned app-only lines (omitted if no backtrace provided).
- **Bot identity** — Posts as "Error Alerts" with a rotating light emoji.

## API Reference

### `ErrorAlerter.configure { |config| ... }`

Set global configuration. Call once at boot (e.g., in a Rails initializer).

### `ErrorAlerter.reset!`

Reset configuration to defaults. Useful in tests.

### `ErrorAlerter.notify(error, context: {})`

Convenience method. Creates a `Notifier` via `from_exception` and calls `notify!`.

Context keys: `:source` (default: "Application"), `:source_detail`, `:queue`.

### `ErrorAlerter::Notifier.new(**kwargs)`

Create a notifier for worker-style errors.

| Kwarg | Required | Default | Description |
|-------|----------|---------|-------------|
| `error_class` | yes | — | Exception class name (e.g., `"RuntimeError"`) |
| `error_message` | yes | — | Exception message |
| `worker_class` | no | nil | Sidekiq worker class name |
| `source` | no | `"Worker"` | Source type for the header |
| `source_detail` | no | `worker_class` | Detailed source (shown in Fields) |
| `queue` | no | nil | Sidekiq queue name |
| `job_id` | no | nil | Sidekiq job ID (not displayed, for future use) |
| `backtrace` | no | nil | Array of backtrace strings |

### `ErrorAlerter::Notifier.from_controller(controller:, error:)`

Factory for controller errors. Sets source to "Controller", source_detail to `"ControllerName#action"`, and extracts backtrace from the error.

### `ErrorAlerter::Notifier.from_exception(error, context: {})`

Factory for general errors. Sets source from `context[:source]` (default: "Application").

### `ErrorAlerter::Notifier#notify!`

Send the alert. Returns `true` on success, `false` if disabled, deduplicated, or failed.

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `webhook_url` | String | nil | Slack Incoming Webhook URL. Alerts are disabled when blank. |
| `dedup_ttl` | Integer | 300 | Deduplication window in seconds. |
| `max_backtrace_lines` | Integer | 5 | Max app-only backtrace lines to include. |
| `max_error_length` | Integer | 500 | Truncate error messages beyond this length. |
| `app_name` | String | nil | Prefix for Slack header (e.g., "CRM Middleware"). |
| `redis` | Object | nil | Redis client responding to `.call(*args)`. Nil disables dedup. |
| `logger` | Logger | nil | Falls back to `Rails.logger` if available. |

## Testing

```bash
bundle install
bundle exec rake test
```

18 tests covering configuration, payload building, dedup, backtrace cleaning, and factory methods.

### Testing in Your App

Use `ErrorAlerter.reset!` in test setup/teardown to isolate config. Stub `ErrorAlerter::SlackClient` to capture payloads without hitting Slack:

```ruby
setup do
  ErrorAlerter.configure do |c|
    c.webhook_url = "https://hooks.slack.com/services/test"
    c.redis = FakeRedis.new
  end
end

teardown do
  ErrorAlerter.reset!
end
```

## Requirements

- Ruby >= 3.0
- A Slack Incoming Webhook URL
- Redis (optional, for deduplication)
