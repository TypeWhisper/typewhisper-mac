#!/usr/bin/env ruby
# Resolves the Mac App Store provisioning profile for the App Store edition
# through the App Store Connect API and writes it to OUTPUT_PATH.
#
# Required environment:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY  App Store Connect API key
#   CERTIFICATE_SERIAL                         serial of the Apple Distribution certificate
#   OUTPUT_PATH                                where to write the .provisionprofile
# Optional environment:
#   BUNDLE_IDENTIFIER  defaults to com.typewhisper.typewhisper-app (shared with iOS)
#   PROFILE_NAME       defaults to "TypeWhisper Mac AppStore <last 8 serial digits>"
#   PROFILE_TYPE       defaults to MAC_APP_STORE
#   RECREATE_PROFILE   "1" deletes profiles with the same name and type first, so
#                      that the new profile picks up current capabilities

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

API_BASE_URL = "https://api.appstoreconnect.apple.com"
DEFAULT_BUNDLE_IDENTIFIER = "com.typewhisper.typewhisper-app"

def required_env(name)
  value = ENV[name]
  abort("Missing required environment variable: #{name}") if value.nil? || value.empty?
  value
end

def optional_env(name, default)
  value = ENV[name]
  value.nil? || value.empty? ? default : value
end

def base64url(value)
  Base64.urlsafe_encode64(value).delete("=")
end

def jwt_token
  header = { alg: "ES256", kid: required_env("ASC_KEY_ID"), typ: "JWT" }
  issued_at = Time.now.to_i
  payload = {
    iss: required_env("ASC_ISSUER_ID"),
    iat: issued_at,
    exp: issued_at + 1_200,
    aud: "appstoreconnect-v1"
  }
  signing_input = [header, payload]
    .map { |part| base64url(JSON.generate(part)) }
    .join(".")
  key = OpenSSL::PKey.read(required_env("ASC_PRIVATE_KEY"))
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  sequence = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest))
  signature = sequence.value.map do |integer|
    [integer.value.to_i.to_s(16).rjust(64, "0")].pack("H*")
  end.join
  "#{signing_input}.#{base64url(signature)}"
end

def api_request(method, path, token, body = nil)
  uri = path.start_with?("http") ? URI(path) : URI("#{API_BASE_URL}#{path}")
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
  unless response.is_a?(Net::HTTPSuccess)
    abort("App Store Connect API request failed (#{response.code}): #{response.body}")
  end
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end

def all_resources(path, token)
  resources = []
  next_path = path
  while next_path
    response = api_request(:get, next_path, token)
    resources.concat(response.fetch("data"))
    next_path = response.dig("links", "next")
  end
  resources
end

def normalized_serial(value)
  value.upcase.gsub(/[^0-9A-F]/, "").sub(/\A0+/, "")
end

token = jwt_token
bundle_identifier = optional_env("BUNDLE_IDENTIFIER", DEFAULT_BUNDLE_IDENTIFIER)
certificate_serial = normalized_serial(required_env("CERTIFICATE_SERIAL"))
profile_name = optional_env("PROFILE_NAME", "TypeWhisper Mac AppStore #{certificate_serial[-8..] || certificate_serial}")
profile_type = optional_env("PROFILE_TYPE", "MAC_APP_STORE")
output_path = required_env("OUTPUT_PATH")

bundle_query = URI.encode_www_form("filter[identifier]" => bundle_identifier, "limit" => "10")
bundle = all_resources("/v1/bundleIds?#{bundle_query}", token).find do |candidate|
  candidate.dig("attributes", "identifier") == bundle_identifier
end
abort("Bundle ID is not registered: #{bundle_identifier}") unless bundle

# The bundle ID is shared with the iOS app. A Mac profile needs it to be
# registered for macOS as well (platform UNIVERSAL or MAC_OS).
bundle_platform = bundle.dig("attributes", "platform")
if profile_type.start_with?("MAC_") && bundle_platform == "IOS"
  warn("Warning: #{bundle_identifier} is registered for platform IOS; " \
       "a #{profile_type} profile requires macOS support for this identifier.")
end

certificate = all_resources("/v1/certificates?limit=200", token).find do |candidate|
  normalized_serial(candidate.dig("attributes", "serialNumber").to_s) == certificate_serial
end
abort("Distribution certificate was not found in App Store Connect") unless certificate

# Only touch profiles with this exact name and type, never the iOS profiles
# that share the bundle identifier.
matching_profiles = all_resources("/v1/profiles?limit=200", token).select do |candidate|
  attributes = candidate.fetch("attributes")
  attributes["name"] == profile_name && attributes["profileType"] == profile_type
end

if ENV["RECREATE_PROFILE"] == "1"
  matching_profiles.each do |candidate|
    api_request(:delete, "/v1/profiles/#{candidate.fetch("id")}", token)
  end
  puts "Removed #{matching_profiles.length} existing profile(s): #{profile_name}"
  matching_profiles = []
end

profile = matching_profiles.find { |candidate| candidate.dig("attributes", "profileState") == "ACTIVE" }

unless profile
  profile = api_request(
    :post,
    "/v1/profiles",
    token,
    {
      data: {
        type: "profiles",
        attributes: { name: profile_name, profileType: profile_type },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle.fetch("id") } },
          certificates: { data: [{ type: "certificates", id: certificate.fetch("id") }] }
        }
      }
    }
  ).fetch("data")
end

profile = api_request(:get, "/v1/profiles/#{profile.fetch("id")}", token).fetch("data")
profile_content = profile.dig("attributes", "profileContent")
abort("App Store Connect returned an empty profile") if profile_content.nil? || profile_content.empty?

File.binwrite(output_path, Base64.strict_decode64(profile_content))
puts "Resolved profile: #{profile.dig("attributes", "name")} (#{profile_type}, #{bundle_identifier})"
