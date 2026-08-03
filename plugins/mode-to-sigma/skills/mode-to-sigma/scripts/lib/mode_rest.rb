# Basic-Auth REST client for the Mode Analytics API (app.mode.com).
# Every request re-sends Basic Auth (token:secret) — Mode has no refreshable
# bearer token, unlike Sigma/Domo, so there is no token-staleness machinery here.
require 'net/http'
require 'json'
require 'uri'

module Mode
  HOST = 'app.mode.com'

  class Error < StandardError; end

  module_function

  def account
    ENV.fetch('MODE_ACCOUNT') { raise Error, 'MODE_ACCOUNT not set' }
  end

  def token
    ENV.fetch('MODE_API_TOKEN') { raise Error, 'MODE_API_TOKEN not set' }
  end

  def secret
    ENV.fetch('MODE_API_SECRET') { raise Error, 'MODE_API_SECRET not set' }
  end

  def http
    h = Net::HTTP.new(HOST, 443)
    h.use_ssl = true
    h.read_timeout = 120
    h
  end

  # Builds a request URI from `path` — which may already carry its own query
  # string, as HAL `_links[...].href` values commonly do (pagination, filtered
  # results) — plus an optional extra `query` Hash/Array to merge in.
  #
  # Parsing the full "https://HOST+path" string with URI() (rather than
  # URI::HTTPS.build's separate host:/path:/query: components) matters: if
  # `path` already contains a literal "?", URI::HTTPS.build raises
  # URI::InvalidComponentError — NOT Mode::Error — which breaks the documented
  # contract that callers only need to rescue Mode::Error.
  def build_uri(path, query = nil)
    uri = URI("https://#{HOST}#{path}")
    if query
      extra = URI.encode_www_form(query)
      uri.query = uri.query ? "#{uri.query}&#{extra}" : extra
    end
    uri
  end

  # Sleep out `Retry-After` (default 2s) and retry the same call exactly once
  # on a 429. RFC 7231 also permits an HTTP-date form for Retry-After (not just
  # delay-seconds), and a header could in principle be malformed — `Integer()`
  # raises ArgumentError (bad string) or TypeError (nil header) in those cases,
  # so fall back to the 2s default rather than blowing up.
  def retry_after_seconds(res)
    Integer(res['Retry-After'])
  rescue ArgumentError, TypeError
    2
  end

  def get(path, query: nil, _retried: false)
    uri = build_uri(path, query)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    req['Accept'] = 'application/json'
    res = http.request(req)
    handle(res)
  rescue Error
    raise unless res.code.to_i == 429 && !_retried
    get(path, query: query, _retried: true)
  end

  # GET without JSON parsing, for CSV/binary responses. Routed through the
  # same handle()-based 429/backoff handling as get/post (rather than its own
  # inline 2xx check) so rate limiting is treated consistently everywhere.
  def get_raw(path, _retried: false)
    uri = build_uri(path)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    res = http.request(req)
    handle(res, parse: false)
  rescue Error
    raise unless res.code.to_i == 429 && !_retried
    get_raw(path, _retried: true)
  end

  def post(path, body:, _retried: false)
    uri = build_uri(path)
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(token, secret)
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req.body = body.to_json
    res = http.request(req)
    handle(res)
  rescue Error
    raise unless res.code.to_i == 429 && !_retried
    post(path, body: body, _retried: true)
  end

  # Follows a HAL `_links[rel].href` on a previously-fetched resource.
  def follow(resource, rel)
    link = resource.dig('_links', rel)
    raise Error, "resource has no _links.#{rel}" unless link
    get(link['href'])
  end

  # `parse: false` returns the raw body string (for get_raw) instead of
  # JSON-parsing it — mirrors domo_rest.rb's handle(res, accept) split for
  # its CSV-export path.
  def handle(res, parse: true)
    code = res.code.to_i
    if code == 429
      sleep(retry_after_seconds(res))
      raise Error, 'rate limited (429) — caller should retry'
    end
    raise Error, "#{res.code}: #{res.body}" unless code.between?(200, 299)
    return (parse ? {} : '') if res.body.nil? || res.body.empty?
    parse ? JSON.parse(res.body) : res.body
  end
end
