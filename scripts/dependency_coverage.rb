#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "set"
require "time"
require "uri"
require "yaml"

# Uses only Ruby's standard library; it never resolves or executes dependencies.
module DependencyCoverage
  ROOT = File.expand_path("..", __dir__)
  LOCKS = %w[
    TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    TypeWhisperPluginSDK/Package.resolved
  ].freeze
  MANIFESTS = (LOCKS + %w[Gemfile Gemfile.lock TypeWhisperPluginSDK/Package.swift TypeWhisper.xcodeproj/project.pbxproj]).freeze

  def self.git(*args)
    output, status = Open3.capture2("git", "-C", ROOT, *args)
    raise "git #{args.first} failed" unless status.success?
    output
  end

  def self.read(path, sha = nil)
    sha ? git("show", "#{sha}:#{path}") : File.read(File.join(ROOT, path))
  end

  def self.purl(pin)
    raise "Unsupported Swift pin kind: #{pin['kind']}" unless pin.fetch("kind") == "remoteSourceControl"
    uri = URI.parse(pin.fetch("location"))
    raise "Unsupported Swift source URL" unless uri.scheme == "https" && uri.host && !uri.userinfo && !uri.query && !uri.fragment
    path = uri.path.delete_suffix(".git").delete_prefix("/")
    raise "Invalid Swift source: #{uri}" if path.split("/").size < 2
    state = pin.fetch("state")
    version = state["version"] || state.fetch("revision")
    raise "Empty Swift version: #{uri}" if version.empty?
    encode = ->(part) { URI.encode_www_form_component(part).gsub("+", "%20") }
    "pkg:swift/#{uri.host}/#{path.split('/').map(&encode).join('/')}@#{encode.call(version)}"
  end

  def self.swift_manifests(sha = nil)
    LOCKS.to_h do |path|
      lock = JSON.parse(read(path, sha))
      raise "Unsupported lock format in #{path}" unless [2, 3].include?(lock.fetch("version"))
      pins = lock.fetch("pins")
      raise "Empty Swift lock: #{path}" if pins.empty?
      resolved = pins.to_h { |pin| [pin.fetch("identity"), { "package_url" => purl(pin) }] }
      raise "Duplicate Swift identities: #{path}" unless resolved.size == pins.size
      # Lockfiles do not encode dependency edges; do not invent directness/scope.
      [path, { "name" => path, "file" => { "source_location" => path }, "resolved" => resolved }]
    end
  end

  def self.check
    tracked = git("ls-files", "-z").split("\0")
    discovered = tracked.select { |p| %w[Package.swift Package.resolved Gemfile Gemfile.lock project.pbxproj].include?(File.basename(p)) }
    raise "Dependency inventory changed: #{(discovered.to_set ^ MANIFESTS.to_set).to_a.join(', ')}" unless discovered.to_set == MANIFESTS.to_set
    config = YAML.safe_load(read(".github/dependabot.yml"))
    raise "Expected Dependabot v2" unless config.fetch("version") == 2
    entries = config.fetch("updates")
    coverage = entries.flat_map do |entry|
      (entry["directories"] || [entry.fetch("directory")]).map { |dir| [entry.fetch("package-ecosystem"), dir] }
    end
    expected = [["github-actions", "/"], ["swift", "/"], ["swift", "/TypeWhisperPluginSDK"], ["bundler", "/"]]
    raise "Dependabot directory coverage changed: #{coverage.inspect}" unless coverage.sort == expected.sort
    entries.each do |entry|
      raise "Security updates must target the default branch" if entry.key?("target-branch")
      raise "Expected weekly version checks" unless entry.dig("schedule", "interval") == "weekly"
      allow = [{ "dependency-name" => "*", "update-types" => %w[version-update:semver-minor version-update:semver-patch] }]
      raise "Expected version-only minor/patch policy" unless entry["allow"] == allow && !entry.key?("ignore")
      groups = entry.fetch("groups").values
      raise "Expected one minor/patch version group" unless groups.size == 1 && groups.first == {
        "applies-to" => "version-updates", "patterns" => ["*"], "update-types" => %w[minor patch]
      }
    end
    manifests = swift_manifests
    manifests.each { |path, manifest| puts "#{path}: #{manifest.fetch('resolved').size} Swift pins" }
    puts "Covered: #{MANIFESTS.size} manifests/locks and #{tracked.count { |p| p.match?(%r{\A.github/workflows/.*\.ya?ml\z}) }} workflows"
  end

  def self.snapshot(sha, ref)
    raise "Expected a full commit SHA" unless sha&.match?(/\A[0-9a-f]{40}\z/)
    raise "Expected a branch ref" unless ref&.start_with?("refs/heads/")
    {
      "version" => 0, "sha" => sha, "ref" => ref,
      "job" => { "id" => ENV.fetch("GITHUB_RUN_ID", "manual-#{sha}"), "correlator" => "swift-lockfiles" },
      "detector" => { "name" => "typewhisper-swift-lockfiles", "version" => "1.0.0",
        "url" => "https://github.com/TypeWhisper/typewhisper-mac" },
      "scanned" => Time.now.utc.iso8601, "manifests" => swift_manifests(sha)
    }
  end

  def self.normalize(purl)
    # GitHub repository names are case-insensitive. Versions remain case-sensitive.
    purl.start_with?("pkg:swift/github.com/") ? purl.split("@", 2).then { |name, version| "#{name.downcase}@#{version}" } : purl
  end

  def self.check_sbom(sbom, sha)
    actual = sbom.fetch("sbom").fetch("packages").flat_map do |package|
      package.fetch("externalRefs", []).filter_map { |ref| normalize(ref.fetch("referenceLocator")) if ref["referenceType"] == "purl" }
    end.to_set
    expected = swift_manifests(sha).values.flat_map { |manifest| manifest.fetch("resolved").values.map { |dep| dep.fetch("package_url") } }
    gems = read("Gemfile.lock", sha).scan(/^    ([A-Za-z0-9_-]+) \(([^ )]+)\)/)
    raise "No Ruby dependencies found" if gems.empty?
    expected.concat(gems.map { |name, version| "pkg:gem/#{name}@#{version}" })
    missing = expected.map { |purl| normalize(purl) }.to_set - actual
    raise "Missing from GitHub SBOM:\n#{missing.to_a.sort.join("\n")}" unless missing.empty?
    puts "GitHub SBOM covers all Swift pins from both locks and #{gems.size} Ruby dependencies at #{sha}."
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.shift
    when "check" then DependencyCoverage.check
    when "snapshot" then puts JSON.pretty_generate(DependencyCoverage.snapshot(ARGV.shift, ARGV.shift))
    when "sbom" then DependencyCoverage.check_sbom(JSON.parse(File.read(ARGV.fetch(0))), ARGV.fetch(1))
    else abort "Usage: ruby scripts/dependency_coverage.rb check | snapshot SHA refs/heads/BRANCH | sbom FILE SHA"
    end
  rescue StandardError => error
    abort error.message
  end
end
