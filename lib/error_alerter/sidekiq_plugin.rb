module ErrorAlerter
  module SidekiqPlugin
    def self.install!
      return unless defined?(::Sidekiq)

      Sidekiq.configure_server do |config|
        config.death_handlers << method(:handle_death)
      end
    end

    def self.handle_death(job, exception)
      Notifier.new(
        worker_class:  job['class'],
        job_id:        job['jid'],
        error_class:   exception.class.name,
        error_message: exception.message,
        queue:         job['queue'],
        backtrace:     exception.backtrace
      ).notify!
    rescue => e
      ErrorAlerter.logger&.error("[ErrorAlerter] death handler failed: #{e.class}: #{e.message}")
    end
  end
end
