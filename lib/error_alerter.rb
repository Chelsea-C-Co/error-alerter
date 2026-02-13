require_relative 'error_alerter/version'
require_relative 'error_alerter/configuration'
require_relative 'error_alerter/slack_client'
require_relative 'error_alerter/notifier'
require_relative 'error_alerter/sidekiq_plugin'
require_relative 'error_alerter/rails_plugin'

module ErrorAlerter
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset!
      @configuration = Configuration.new
    end

    def notify(error, context: {})
      Notifier.from_exception(error, context: context).notify!
    end

    def logger
      configuration.logger || (defined?(Rails) ? Rails.logger : nil)
    end
  end
end
