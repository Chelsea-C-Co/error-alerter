require 'digest'

module ErrorAlerter
  module HealthCheck
    DEDUP_TTL = 43_200 # 12 hours

    def self.run!
      config = ErrorAlerter.configuration
      return false unless config.enabled?

      failures = []
      failures << check_disk(config.health_check_disk_threshold)
      failures << check_ram(config.health_check_ram_threshold)
      failures << check_docker(config.health_check_docker_threshold)
      failures.compact!

      return true if failures.empty?
      return false if deduplicated?(failures, config)

      post_alert(failures, config)
    end

    def self.check_disk(threshold)
      output = `df -P / 2>/dev/null`.strip
      return nil if output.empty?

      line = output.lines[1]
      return nil unless line

      pct = line.split[4].to_i # "42%" → 42
      return nil if pct <= threshold

      { check: "Disk Usage", value: "#{pct}%", threshold: "#{threshold}%" }
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter::HealthCheck] disk check failed: #{e.message}")
      nil
    end

    def self.check_ram(threshold)
      output = `free -m 2>/dev/null`.strip
      return nil if output.empty?

      mem_line = output.lines.find { |l| l.start_with?("Mem:") }
      return nil unless mem_line

      parts = mem_line.split
      total = parts[1].to_f
      available = parts[6].to_f # "available" column is more accurate than "free"
      return nil if total <= 0

      used_pct = ((total - available) / total * 100).round
      return nil if used_pct <= threshold

      { check: "RAM Usage", value: "#{used_pct}%", threshold: "#{threshold}%" }
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter::HealthCheck] RAM check failed: #{e.message}")
      nil
    end

    def self.check_docker(threshold_gb)
      output = `docker system df --format '{{.Reclaimable}}' 2>/dev/null`.strip
      return nil if output.empty?

      total_gb = 0.0
      output.lines.each do |line|
        line = line.strip
        if line =~ /^(\d+\.?\d*)(kB|KB|MB|GB|TB)/
          value = $1.to_f
          unit = $2
          total_gb += case unit
                      when "TB" then value * 1024
                      when "GB" then value
                      when "MB" then value / 1024.0
                      when "kB", "KB" then value / (1024.0 * 1024.0)
                      else 0
                      end
        end
      end

      return nil if total_gb <= threshold_gb

      { check: "Docker Reclaimable", value: "#{'%.1f' % total_gb}GB", threshold: "#{threshold_gb}GB" }
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter::HealthCheck] Docker check failed: #{e.message}")
      nil
    end

    private_class_method :check_disk, :check_ram, :check_docker

    def self.deduplicated?(failures, config)
      redis = config.redis
      return false unless redis

      fingerprint = Digest::MD5.hexdigest(failures.map { |f| f[:check] }.sort.join(":"))
      key = "error_alerter:health:#{fingerprint}"

      already_sent = !redis.call("SET", key, "1", "NX", "EX", DEDUP_TTL.to_s)
      already_sent
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter::HealthCheck] dedup check failed, proceeding: #{e.message}")
      false
    end
    private_class_method :deduplicated?

    def self.post_alert(failures, config)
      timestamp = if defined?(Time.current)
                    Time.current.in_time_zone('Eastern Time (US & Canada)')
                         .strftime('%b %d, %Y %l:%M %p ET').strip
                  else
                    Time.now.strftime('%b %d, %Y %l:%M %p UTC').strip
                  end

      header = "Server Health Warning"
      header = "#{config.app_name}: #{header}" if config.app_name

      detail_lines = failures.map { |f| "\u2022 *#{f[:check]}:* #{f[:value]} (threshold: #{f[:threshold]})" }

      blocks = [
        { type: 'header', text: { type: 'plain_text', text: header, emoji: true } },
        { type: 'section', text: { type: 'mrkdwn', text: detail_lines.join("\n") } },
        { type: 'context', elements: [{ type: 'mrkdwn', text: timestamp }] }
      ]

      client = SlackClient.new(url: config.webhook_url)
      client.post({ icon_emoji: ':warning:', username: 'Server Health', blocks: blocks })
    end
    private_class_method :post_alert
  end
end
