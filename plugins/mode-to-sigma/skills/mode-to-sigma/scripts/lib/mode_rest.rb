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

  def get(path, query: nil)
    uri = URI::HTTPS.build(host: HOST, path: path, query: query && URI.encode_www_form(query))
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    req['Accept'] = 'application/json'
    handle(http.request(req))
  end

  def get_raw(path)
    uri = URI::HTTPS.build(host: HOST, path: path)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    res = http.request(req)
    raise Error, "GET #{path} -> #{res.code}: #{res.body}" unless res.code.to_i.between?(200, 299)
    res.body
  end

  def post(path, body:)
    uri = URI::HTTPS.build(host: HOST, path: path)
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(token, secret)
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req.body = body.to_json
    handle(http.request(req))
  end

  # Follows a HAL `_links[rel].href` on a previously-fetched resource.
  def follow(resource, rel)
    link = resource.dig('_links', rel)
    raise Error, "resource has no _links.#{rel}" unless link
    get(link['href'])
  end

  def handle(res)
    code = res.code.to_i
    if code == 429
      sleep(Integer(res['Retry-After'] || '2'))
      raise Error, 'rate limited (429) — caller should retry'
    end
    raise Error, "#{res.code}: #{res.body}" unless code.between?(200, 299)
    return {} if res.body.nil? || res.body.empty?
    JSON.parse(res.body)
  end
end
