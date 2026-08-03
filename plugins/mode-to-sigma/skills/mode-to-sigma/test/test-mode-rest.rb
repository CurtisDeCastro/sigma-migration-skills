#!/usr/bin/env ruby
# Unit tests for mode_rest.rb against a stubbed Net::HTTP — no live network.
#   ruby test/test-mode-rest.rb
require_relative '../scripts/lib/mode_rest'
require 'json'
require 'uri'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

ENV['MODE_ACCOUNT']    = 'acme'
ENV['MODE_API_TOKEN']  = 'tok123'
ENV['MODE_API_SECRET'] = 'sec456'

# A minimal duck-typed response double: real Net::HTTPResponse quacks like
# this (.code, .body, .[](header)) — handle() only ever calls these three, so
# a fake is enough to exercise it directly with no network/stubbing needed.
FakeResponse = Struct.new(:code, :body, :headers) do
  def [](key)
    (headers || {})[key]
  end
end

# Stands in for Mode.http. Returns canned responses in order (repeating the
# last one past the end) and counts how many requests were made, so tests can
# assert the retry logic fires exactly once — not zero, not unboundedly.
class FakeHTTP
  attr_reader :call_count

  def initialize(*responses)
    @responses = responses
    @call_count = 0
  end

  def request(_req)
    res = @responses[@call_count] || @responses.last
    @call_count += 1
    res
  end
end

orig_get  = Mode.method(:get)
orig_http = Mode.method(:http)

puts "== Mode.follow =="
resource = { '_links' => { 'query_runs' => { 'href' => '/api/acme/reports/r1/runs/run1/query_runs' } } }
# Stub Mode.get so follow() doesn't hit the network
Mode.define_singleton_method(:get) { |path, query: nil| { 'stubbed_path' => path } }
result = Mode.follow(resource, 'query_runs')
eq(result['stubbed_path'], '/api/acme/reports/r1/runs/run1/query_runs', 'follow() calls get() on the href')

begin
  Mode.follow(resource, 'missing_rel')
  $failures += 1; puts "  FAIL: follow() should raise on a missing rel"
rescue Mode::Error => e
  eq(e.message.include?('missing_rel'), true, 'follow() raises Mode::Error naming the missing rel')
end

# Restore the real get() for the rest of the suite.
Mode.define_singleton_method(:get, orig_get)

puts "== Finding 1: build_uri handles a path that already carries a query string =="
uri = Mode.build_uri('/api/acme/reports/r1/runs?page=2')
eq(uri.to_s, 'https://app.mode.com/api/acme/reports/r1/runs?page=2',
   'build_uri parses a path with an embedded query string without raising')

merged = Mode.build_uri('/api/acme/reports/r1/runs?page=2', { limit: 10 })
eq(merged.query, 'page=2&limit=10',
   'build_uri merges an extra query: param onto a path that already has one')

puts "== Finding 1: get()/follow() with a query-string href — no URI::InvalidComponentError =="
fake_ok = FakeHTTP.new(FakeResponse.new('200', '{"runs":[]}', {}))
Mode.define_singleton_method(:http) { fake_ok }

begin
  result = Mode.get('/api/acme/reports/r1/runs?page=2')
  eq(result, { 'runs' => [] }, 'get() succeeds against a query-string-bearing path')
rescue URI::InvalidComponentError => e
  $failures += 1; puts "  FAIL: get() raised URI::InvalidComponentError: #{e.message}"
end

paged_resource = { '_links' => { 'next_page' => { 'href' => '/api/acme/reports/r1/runs?page=2' } } }
begin
  result = Mode.follow(paged_resource, 'next_page')
  eq(result, { 'runs' => [] }, 'follow() succeeds when the href contains a query string')
rescue URI::InvalidComponentError => e
  $failures += 1; puts "  FAIL: follow() raised URI::InvalidComponentError: #{e.message}"
end

Mode.define_singleton_method(:http, orig_http)

puts "== Finding 3 (minor): Mode.handle direct branch coverage =="
eq(Mode.handle(FakeResponse.new('200', '{"a":1}', {})), { 'a' => 1 },
   'handle() parses a 2xx JSON body')
eq(Mode.handle(FakeResponse.new('204', '', {})), {},
   'handle() returns {} for an empty 2xx body')
eq(Mode.handle(FakeResponse.new('200', 'a,b,c', {}), parse: false), 'a,b,c',
   'handle(parse: false) returns the raw body string (get_raw path)')
eq(Mode.handle(FakeResponse.new('200', '', {}), parse: false), '',
   'handle(parse: false) returns "" for an empty body rather than nil')

begin
  Mode.handle(FakeResponse.new('429', '', { 'Retry-After' => '0' }))
  $failures += 1; puts "  FAIL: handle() should raise on 429"
rescue Mode::Error => e
  eq(e.message.include?('429'), true, 'handle() sleeps out Retry-After then raises Mode::Error on 429')
end

begin
  Mode.handle(FakeResponse.new('500', 'boom', {}))
  $failures += 1; puts "  FAIL: handle() should raise on non-2xx"
rescue Mode::Error => e
  eq(e.message.include?('500') && e.message.include?('boom'), true,
     'handle() raises Mode::Error with code+body on non-2xx')
end

eq(Mode.retry_after_seconds(FakeResponse.new('429', '', { 'Retry-After' => 'not-a-number' })), 2,
   'retry_after_seconds falls back to 2 on a malformed (e.g. HTTP-date) Retry-After header')
eq(Mode.retry_after_seconds(FakeResponse.new('429', '', {})), 2,
   'retry_after_seconds falls back to 2 when Retry-After is absent')
eq(Mode.retry_after_seconds(FakeResponse.new('429', '', { 'Retry-After' => '5' })), 5,
   'retry_after_seconds honors a well-formed Retry-After header')

puts "== Finding 2: 429 handling retries exactly once, then either succeeds or raises =="

def retry_succeeds(label)
  fake = FakeHTTP.new(
    FakeResponse.new('429', '', { 'Retry-After' => '0' }),
    FakeResponse.new('200', '{"ok":true}', {})
  )
  Mode.define_singleton_method(:http) { fake }
  result = yield
  parsed = result.is_a?(String) ? JSON.parse(result) : result
  eq(parsed, { 'ok' => true }, "#{label} retries once after 429 and returns the successful result")
  eq(fake.call_count, 2, "#{label} made exactly 2 HTTP requests (1 initial + 1 retry) for a single 429")
end

def retry_exhausted(label)
  fake = FakeHTTP.new(
    FakeResponse.new('429', '', { 'Retry-After' => '0' }),
    FakeResponse.new('429', '', { 'Retry-After' => '0' })
  )
  Mode.define_singleton_method(:http) { fake }
  begin
    yield
    $failures += 1; puts "  FAIL: #{label} should raise Mode::Error when still 429 after the retry"
  rescue Mode::Error => e
    eq(e.message.include?('429'), true, "#{label} raises Mode::Error once the single retry is exhausted")
  end
  eq(fake.call_count, 2, "#{label} does not loop unboundedly — exactly 2 requests for a persistent 429")
end

retry_succeeds('get()')   { Mode.get('/api/acme/single-retry') }
retry_exhausted('get()')  { Mode.get('/api/acme/single-retry') }

retry_succeeds('post()')  { Mode.post('/api/acme/single-retry', body: { x: 1 }) }
retry_exhausted('post()') { Mode.post('/api/acme/single-retry', body: { x: 1 }) }

retry_succeeds('get_raw()')  { Mode.get_raw('/api/acme/single-retry') }
retry_exhausted('get_raw()') { Mode.get_raw('/api/acme/single-retry') }

Mode.define_singleton_method(:http, orig_http)

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
