require "minitest/autorun"
require "minitest/mock" # for Object#stub used in the notify! tests
require "error_alerter"

# Minimal fake Redis for dedup tests. In-memory; TTLs are accepted but not enforced
# (expiry behavior is covered by the pure suppression_ttl logic, not wall-clock here).
class FakeRedis
  attr_reader :store

  def initialize
    @store = {}
  end

  def call(*args)
    cmd = args[0].upcase
    case cmd
    when "SET"
      key, value = args[1], args[2]
      nx = args.include?("NX")
      if nx && @store.key?(key)
        nil
      else
        @store[key] = value
        "OK"
      end
    when "GET"
      @store[args[1]]
    when "DEL"
      @store.delete(args[1]) ? 1 : 0
    when "INCR"
      @store[args[1]] = (@store[args[1]].to_i + 1)
      @store[args[1]]
    when "EXISTS"
      @store.key?(args[1]) ? 1 : 0
    when "EXPIRE"
      @store.key?(args[1]) ? 1 : 0 # accepted, not enforced
    end
  end
end
