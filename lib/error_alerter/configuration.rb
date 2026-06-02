module ErrorAlerter
  class Configuration
    attr_accessor :webhook_url, :dedup_ttl, :max_backtrace_lines, :max_error_length,
                  :app_name, :redis, :logger,
                  :health_check_disk_threshold, :health_check_ram_threshold,
                  :health_check_docker_threshold,
                  :severity_classifier, :critical_mention, :backoff_schedule

    def initialize
      @webhook_url = nil
      @dedup_ttl = 300 # 5 minutes
      @max_backtrace_lines = 5
      @max_error_length = 500
      @app_name = nil
      @redis = nil
      @logger = nil
      @health_check_disk_threshold = 80    # percentage
      @health_check_ram_threshold = 85     # percentage
      @health_check_docker_threshold = 5   # GB

      # --- Severity (opt-in; nil => current behavior, no severity rendering) ---
      # A callable (error_class, source_detail, error_message) => :critical | :warning | :transient.
      # When set, alerts get a colored attachment border + severity emoji, and :critical alerts
      # prepend `critical_mention` (e.g. "<!here>").
      @severity_classifier = nil
      @critical_mention    = nil

      # --- Burst/backoff dedup (opt-in; nil => flat `dedup_ttl`) ---
      # An array of escalating suppression TTLs in seconds, e.g. [300, 1800, 7200]. A flapping
      # error alerts, then is suppressed for progressively longer windows instead of re-firing
      # every `dedup_ttl`. The next alert reports how many occurrences were suppressed.
      @backoff_schedule = nil
    end

    def enabled?
      webhook_url.to_s.strip.length > 0
    end
  end
end
