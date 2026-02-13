module ErrorAlerter
  class Configuration
    attr_accessor :webhook_url, :dedup_ttl, :max_backtrace_lines, :max_error_length,
                  :app_name, :redis, :logger

    def initialize
      @webhook_url = nil
      @dedup_ttl = 300 # 5 minutes
      @max_backtrace_lines = 5
      @max_error_length = 500
      @app_name = nil
      @redis = nil
      @logger = nil
    end

    def enabled?
      webhook_url.to_s.strip.length > 0
    end
  end
end
