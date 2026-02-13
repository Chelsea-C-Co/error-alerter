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
  config.webhook_url         = ENV['SLACK_ERROR_WEBHOOK_URL']
  config.dedup_ttl           = 300  # seconds (default: 5 minutes)
  config.max_backtrace_lines = 5    # default
  config.max_error_length    = 500  # default
  config.app_name            = "My App"  # optional, prefixes Slack header

  # Redis for deduplication (optional — without it, every error alerts)
  config.redis = Sidekiq.redis_pool  # or any object responding to #call("SET", ...)
end
```

## Usage

### Rails Controllers

Include `ErrorAlerter::RailsPlugin` in your base controller. It adds a `rescue_from StandardError` that sends a Slack alert, then re-raises the error so your existing error handling still works.

```ruby
class Webhooks::BaseController < ActionController::API
  include ErrorAlerter::RailsPlugin

  # Your existing rescue_from handlers run first (more specific wins).
  # ErrorAlerter catches anything that falls through.
end
```

### Sidekiq Workers

Auto-register a death handler that alerts when a job exhausts all retries:

```ruby
# config/initializers/error_alerter.rb (after configure block)
ErrorAlerter::SidekiqPlugin.install!
```

### Manual

```ruby
begin
  do_something_risky
rescue => e
  ErrorAlerter.notify(e, context: { source: "Rake", source_detail: "backfill:run" })
end
```

## Deduplication

When Redis is configured, the same error (class + source + message) only alerts once per `dedup_ttl` window. If Redis is unavailable, alerts send without dedup (fail open).

## Slack Message Format

```
[Header] Worker Failed  (or "Controller Failed", "MyApp: Worker Failed")
[Fields] Source: TransactionSyncWorker | Error: RuntimeError | Time: Feb 11, 2026 3:45 PM ET
[Section] Message: ```connection refused```
[Section] Backtrace: ```app/services/crm_service.rb:42:in 'upsert'```
```

## Testing

```bash
bundle install
bundle exec rake test
```
