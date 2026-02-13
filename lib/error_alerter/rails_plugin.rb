module ErrorAlerter
  module RailsPlugin
    def self.included(base)
      base.rescue_from StandardError, with: :_error_alerter_handle
    end

    private

    def _error_alerter_handle(error)
      begin
        ErrorAlerter::Notifier.from_controller(controller: self, error: error).notify!
      rescue => e
        ErrorAlerter.logger&.error("[ErrorAlerter] controller notify failed: #{e.class}: #{e.message}")
      end

      raise error
    end
  end
end
