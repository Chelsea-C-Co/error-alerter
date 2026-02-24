module ErrorAlerter
  class Configuration
    attr_accessor :webhook_url, :dedup_ttl, :max_backtrace_lines, :max_error_length,
                  :app_name, :redis, :logger,
                  :health_check_disk_threshold, :health_check_ram_threshold,
                  :health_check_docker_threshold

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
    end

    def enabled?
      webhook_url.to_s.strip.length > 0
    end
  end
end
