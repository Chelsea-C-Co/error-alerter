require 'digest'

module ErrorAlerter
  class Notifier
    # Severity → Slack attachment color + emoji. Only used when a severity_classifier is configured.
    SEVERITY_STYLES = {
      critical:  { emoji: ':rotating_light:',    color: '#E01E5A' }, # red
      warning:   { emoji: ':warning:',           color: '#ECB22E' }, # yellow
      transient: { emoji: ':large_blue_circle:', color: '#36C5F0' }  # blue
    }.freeze

    def self.from_controller(controller:, error:)
      new(
        source:        "Controller",
        source_detail: "#{controller.class.name}##{controller.action_name}",
        error_class:   error.class.name,
        error_message: error.message,
        backtrace:     error.backtrace
      )
    end

    def self.from_exception(error, context: {})
      new(
        source:        context[:source] || "Application",
        source_detail: context[:source_detail],
        error_class:   error.class.name,
        error_message: error.message,
        backtrace:     error.backtrace,
        queue:         context[:queue]
      )
    end

    def initialize(source: "Worker", source_detail: nil, worker_class: nil,
                   error_class:, error_message:, queue: nil, job_id: nil,
                   backtrace: nil)
      @source        = source
      @source_detail = source_detail || worker_class
      @error_class   = error_class
      @error_message = error_message.to_s[0, config.max_error_length]
      @queue         = queue
      @job_id        = job_id
      @backtrace     = backtrace
    end

    def notify!
      return false unless config.enabled?
      return false if deduplicated?

      client = SlackClient.new(url: config.webhook_url)
      client.post(build_payload)
    end

    private

    def config
      ErrorAlerter.configuration
    end

    def fingerprint
      @fingerprint ||= Digest::MD5.hexdigest("#{@error_class}:#{@source_detail}:#{@error_message}")
    end

    # Returns true if this occurrence should be suppressed. The first occurrence claims an alert
    # slot (always with a TTL, so a crash can never suppress forever); repeats within the window
    # are suppressed and counted. With `backoff_schedule` set, each alert escalates the suppression
    # window and the next alert reports how many were suppressed. A nil schedule => flat `dedup_ttl`
    # (identical to pre-sc-493 behavior; no counters touched).
    def deduplicated?
      redis = config.redis
      return false unless redis

      key = "error_alerter:#{fingerprint}"
      claimed = redis.call("SET", key, "1", "NX", "EX", config.dedup_ttl.to_s)

      if claimed
        if backoff?
          redis.call("EXPIRE", key, suppression_ttl(redis).to_s)
          @suppressed_count = take_suppressed_count(redis)
        end
        false
      else
        record_suppressed(redis) if backoff?
        true
      end
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter] dedup check failed, proceeding: #{e.class}: #{e.message}")
      false
    end

    def backoff?
      s = config.backoff_schedule
      s.respond_to?(:any?) && s.any?
    end

    # Escalating suppression window: tier N (incremented per alert, not per occurrence) →
    # schedule[N-1], clamped to the last entry. The tier counter resets after the longest window.
    def suppression_ttl(redis)
      schedule = config.backoff_schedule
      tier_key = "error_alerter:tier:#{fingerprint}"
      tier = redis.call("INCR", tier_key).to_i
      redis.call("EXPIRE", tier_key, schedule.last.to_s)
      schedule[[tier - 1, schedule.length - 1].min].to_i
    end

    def record_suppressed(redis)
      occ_key = "error_alerter:occ:#{fingerprint}"
      redis.call("INCR", occ_key)
      redis.call("EXPIRE", occ_key, config.backoff_schedule.last.to_s)
    end

    def take_suppressed_count(redis)
      occ_key = "error_alerter:occ:#{fingerprint}"
      val = redis.call("GET", occ_key)
      redis.call("DEL", occ_key)
      val.to_i
    end

    # nil unless a severity_classifier is configured. Memoized (defined? handles a nil result).
    def severity
      return @severity if defined?(@severity)

      @severity = compute_severity
    end

    def compute_severity
      classifier = config.severity_classifier
      return nil unless classifier

      result = classifier.call(@error_class, @source_detail, @error_message)
      SEVERITY_STYLES.key?(result) ? result : :warning
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter] severity_classifier raised, defaulting to :warning: #{e.class}: #{e.message}")
      :warning
    end

    def build_payload
      blocks = build_blocks

      if severity
        style = SEVERITY_STYLES[severity]
        { icon_emoji: style[:emoji], username: 'Error Alerts',
          attachments: [{ color: style[:color], blocks: blocks }] }
      else
        # Unchanged pre-sc-493 payload when severity is not configured.
        { icon_emoji: ':rotating_light:', username: 'Error Alerts', blocks: blocks }
      end
    end

    def build_blocks
      blocks = []

      if severity == :critical && config.critical_mention
        blocks << { type: 'section', text: { type: 'mrkdwn', text: config.critical_mention.to_s } }
      end

      blocks << { type: 'header', text: { type: 'plain_text', text: header_text, emoji: true } }
      blocks << { type: 'section', fields: payload_fields }
      blocks << { type: 'section', text: { type: 'mrkdwn', text: "*Message:*\n```#{@error_message}```" } }

      if @backtrace&.any?
        cleaned = cleaned_backtrace
        if cleaned.any?
          trace_text = cleaned.first(config.max_backtrace_lines).join("\n")
          blocks << { type: 'section', text: { type: 'mrkdwn', text: "*Backtrace:*\n```#{trace_text}```" } }
        end
      end

      if @suppressed_count.to_i.positive?
        blocks << { type: 'context', elements: [
          { type: 'mrkdwn', text: ":repeat: #{@suppressed_count} more occurrence(s) suppressed since the last alert" }
        ] }
      end

      blocks
    end

    def header_text
      header = "#{@source} Failed"
      header = "#{config.app_name}: #{header}" if config.app_name
      header
    end

    def payload_fields
      fields = [
        { type: 'mrkdwn', text: "*Source:*\n`#{@source_detail}`" },
        { type: 'mrkdwn', text: "*Error:*\n`#{@error_class}`" },
        { type: 'mrkdwn', text: "*Time:*\n#{timestamp}" }
      ]
      fields << { type: 'mrkdwn', text: "*Queue:*\n#{@queue}" } if @queue
      fields
    end

    def timestamp
      if defined?(Time.current)
        Time.current.in_time_zone('Eastern Time (US & Canada)')
            .strftime('%b %d, %Y %l:%M %p ET').strip
      else
        Time.now.strftime('%b %d, %Y %l:%M %p UTC').strip
      end
    end

    def cleaned_backtrace
      return [] unless @backtrace

      app_root = defined?(Rails) ? Rails.root.to_s : Dir.pwd

      @backtrace
        .select { |line| line.include?(app_root) }
        .map { |line| line.sub(app_root + '/', '') }
    end
  end
end
