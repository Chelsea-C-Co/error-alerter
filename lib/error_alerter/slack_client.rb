require 'net/http'
require 'uri'
require 'json'

module ErrorAlerter
  class SlackClient
    def initialize(url:, open_timeout: 4, read_timeout: 6)
      @url = url.to_s.strip
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def post(payload)
      return false if @url.empty?

      uri = URI(@url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = payload.to_json

      resp = http.request(req)
      resp.is_a?(Net::HTTPSuccess)
    rescue => e
      ErrorAlerter.logger&.warn("[ErrorAlerter] Slack post failed: #{e.class}: #{e.message}")
      false
    end
  end
end
