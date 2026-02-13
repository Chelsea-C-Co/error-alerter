# ErrorAlerter

## Overview
Standalone Ruby gem for lightweight error monitoring. Posts Slack alerts with Redis-based deduplication, cleaned backtraces, and Block Kit formatting. Designed for Rails + Sidekiq apps as a stepping stone before dedicated services like Sentry.

**Repo:** Chelsea-C-Co/error-alerter
**Consumer:** Chelsea-C-Co/crm-middleware (integrated via `gem 'error_alerter', github: 'Chelsea-C-Co/error-alerter'`)

## Tech Stack
- **Ruby:** >= 3.0 (developed on 3.4.5)
- **Dependencies:** `json` (stdlib)
- **Test framework:** Minitest
- **No Rails dependency** — works with or without Rails

## Architecture

```
ErrorAlerter (module)
├── Configuration      — config DSL (webhook_url, dedup_ttl, redis, etc.)
├── Notifier           — core logic: dedup, backtrace cleaning, payload building
│   ├── .from_controller(controller:, error:)
│   ├── .from_exception(error, context:)
│   └── #notify!
├── SlackClient        — HTTP POST to Slack webhook (net/http)
├── RailsPlugin        — rescue_from mixin for controllers
└── SidekiqPlugin      — death handler auto-registration
```

### Key Design Decisions

- **Redis `.call(*args)` interface** — The gem uses the Redis command protocol (`redis.call("SET", key, value, "NX", "EX", ttl)`), NOT Ruby keyword arguments. This matches `redis-client` gem and Sidekiq's internal connection interface. Sidekiq apps need a `SidekiqRedisProxy` wrapper (see README).
- **RailsPlugin re-raises** — After notifying, the error is re-raised so the app's own `rescue_from` or error handling still runs. This means `RailsPlugin` is composable with custom handlers.
- **Fail-open dedup** — If Redis is unavailable, dedup is skipped and the alert sends. Never silently swallow an error.
- **Dedup fingerprint** — MD5 of `"#{error_class}:#{source_detail}:#{error_message}"`. Same error class + same source + same message = same fingerprint.
- **Rails-optional** — Uses `Time.current` and `Rails.root` when available, falls back to `Time.now` and `Dir.pwd` for plain Ruby.

## File Structure

```
lib/
  error_alerter.rb              — Entry point, configure/reset!/notify class methods
  error_alerter/
    version.rb                  — VERSION constant
    configuration.rb            — Config DSL with defaults
    notifier.rb                 — Core notification logic
    slack_client.rb             — HTTP client for Slack webhooks
    rails_plugin.rb             — rescue_from mixin
    sidekiq_plugin.rb           — Sidekiq death handler registration

test/
  test_helper.rb                — Minitest setup + FakeRedis helper
  notifier_test.rb              — 14 tests (payload, dedup, factories, backtrace)
  configuration_test.rb         — 4 tests (defaults, enabled/disabled, reset)
```

## Testing
```bash
bundle install
bundle exec rake test
```

18 tests total. All tests run without Redis — `FakeRedis` in `test/test_helper.rb` provides an in-memory implementation of the `.call()` interface.

## Coding Guidelines
- Keep the gem minimal — no unnecessary dependencies
- All Slack communication goes through `SlackClient`
- All dedup logic lives in `Notifier#deduplicated?`
- Factory methods (`from_controller`, `from_exception`) are the public API for creating notifiers from different contexts
- `#notify!` is the only method that triggers side effects (Slack POST, Redis SET)

## Version
Current: 0.1.0 (pre-release, GitHub source only, not published to RubyGems)
