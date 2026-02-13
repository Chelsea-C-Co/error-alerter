require 'digest'

module ErrorAlerter
  class Notifier
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

    def deduplicated?
      redis = config.redis
      return false unless redis

      fingerprint = Digest::MD5.hexdigest("#{@error_class}:#{@source_detail}:#{@error_message}")
      key = "error_alerter:#{fingerprint}"

      already_sent = !redis.call("SET", key, "1", "NX", "EX", config.dedup_ttl.to_s)
      already_sent
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter] dedup check failed, proceeding: #{e.class}: #{e.message}")
      false
    end

    def build_payload
      timestamp = if defined?(Time.current)
                    Time.current.in_time_zone('Eastern Time (US & Canada)')
                         .strftime('%b %d, %Y %l:%M %p ET').strip
                  else
                    Time.now.strftime('%b %d, %Y %l:%M %p UTC').strip
                  end

      fields = [
        { type: 'mrkdwn', text: "*Source:*\n`#{@source_detail}`" },
        { type: 'mrkdwn', text: "*Error:*\n`#{@error_class}`" },
        { type: 'mrkdwn', text: "*Time:*\n#{timestamp}" }
      ]
      fields << { type: 'mrkdwn', text: "*Queue:*\n#{@queue}" } if @queue

      header = "#{@source} Failed"
      header = "#{config.app_name}: #{header}" if config.app_name

      blocks = [
        { type: 'header', text: { type: 'plain_text', text: header, emoji: true } },
        { type: 'section', fields: fields },
        { type: 'section', text: { type: 'mrkdwn', text: "*Message:*\n```#{@error_message}```" } }
      ]

      if @backtrace&.any?
        cleaned = cleaned_backtrace
        if cleaned.any?
          trace_text = cleaned.first(config.max_backtrace_lines).join("\n")
          blocks << { type: 'section', text: { type: 'mrkdwn', text: "*Backtrace:*\n```#{trace_text}```" } }
        end
      end

      { icon_emoji: ':rotating_light:', username: 'Error Alerts', blocks: blocks }
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
