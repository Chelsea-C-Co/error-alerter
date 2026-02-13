require_relative 'lib/error_alerter/version'

Gem::Specification.new do |spec|
  spec.name          = "error_alerter"
  spec.version       = ErrorAlerter::VERSION
  spec.authors       = ["Chelsea Cannabis Co"]
  spec.summary       = "Lightweight error monitoring — Slack alerts with dedup and backtrace"
  spec.description   = "Drop-in error alerting for Rails + Sidekiq apps. Posts to Slack with " \
                        "Redis-based deduplication, cleaned backtraces, and Block Kit formatting."
  spec.homepage      = "https://github.com/Chelsea-C-Co/error-alerter"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json"
end
