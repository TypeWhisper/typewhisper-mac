# frozen_string_literal: true

require "minitest/autorun"
require_relative "dependency_coverage"

class DependencyCoverageTest < Minitest::Test
  def pin(state)
    { "identity" => "example", "kind" => "remoteSourceControl",
      "location" => "https://github.com/Owner/Example.git", "state" => state }
  end

  def test_versions_and_revision_only_pins
    assert_equal "pkg:swift/github.com/Owner/Example@1.2.3", DependencyCoverage.purl(pin({ "version" => "1.2.3", "revision" => "abc" }))
    assert_equal "pkg:swift/github.com/Owner/Example@abc", DependencyCoverage.purl(pin({ "revision" => "abc", "branch" => "main" }))
    assert_equal "pkg:swift/github.com/Owner/Example@1.0%2Bbuild", DependencyCoverage.purl(pin({ "version" => "1.0+build" }))
  end

  def test_unsupported_and_incomplete_pins_fail_instead_of_disappearing
    assert_raises(RuntimeError) { DependencyCoverage.purl(pin({ "version" => "1" }).merge("kind" => "registry")) }
    assert_raises(KeyError) { DependencyCoverage.purl(pin({})) }
    assert_raises(RuntimeError) { DependencyCoverage.purl(pin({ "version" => "1" }).merge("location" => "https://user:secret@example.com/a/b")) }
  end

  def test_snapshot_preserves_both_manifests_and_does_not_invent_edges
    sha = DependencyCoverage.git("rev-parse", "HEAD").strip
    snapshot = DependencyCoverage.snapshot(sha, "refs/heads/main")
    assert_equal DependencyCoverage::LOCKS.sort, snapshot.fetch("manifests").keys.sort
    snapshot.fetch("manifests").each do |path, manifest|
      pins = JSON.parse(DependencyCoverage.read(path, sha)).fetch("pins")
      assert_equal pins.size, manifest.fetch("resolved").size
      assert manifest.fetch("resolved").values.all? { |dep| dep.keys == ["package_url"] }
    end
    assert_equal sha, snapshot.fetch("sha")
    assert_raises(RuntimeError) { DependencyCoverage.snapshot("HEAD", "refs/heads/main") }
  end

  def test_sbom_requires_every_version_including_different_versions_between_locks
    sha = DependencyCoverage.git("rev-parse", "HEAD").strip
    purls = DependencyCoverage.swift_manifests(sha).values.flat_map { |m| m.fetch("resolved").values.map { |d| d.fetch("package_url") } }
    purls.concat(DependencyCoverage.read("Gemfile.lock", sha).scan(/^    ([A-Za-z0-9_-]+) \(([^ )]+)\)/).map { |n, v| "pkg:gem/#{n}@#{v}" })
    sbom = { "sbom" => { "packages" => purls.uniq.map { |url| { "externalRefs" => [{ "referenceType" => "purl", "referenceLocator" => DependencyCoverage.normalize(url) }] } } } }
    capture_io { DependencyCoverage.check_sbom(sbom, sha) }
    sbom["sbom"]["packages"].shift
    assert_raises(RuntimeError) { DependencyCoverage.check_sbom(sbom, sha) }
  end
end
