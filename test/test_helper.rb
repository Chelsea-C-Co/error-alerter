require "minitest/autorun"
require "error_alerter"

# Minimal fake Redis for dedup tests
class FakeRedis
  def initialize
    @store = {}
  end

  def call(*args)
    cmd = args[0].upcase
    case cmd
    when "SET"
      key, value = args[1], args[2]
      nx = args.include?("NX")
      ex_idx = args.index("EX")
      if nx && @store.key?(key)
        nil
      else
        @store[key] = value
        "OK"
      end
    when "DEL"
      @store.delete(args[1]) ? 1 : 0
    end
  end
end
