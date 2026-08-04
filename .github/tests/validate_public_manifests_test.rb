# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"

require_relative "../scripts/validate_public_manifests"

class ValidatePublicManifestsTest < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  FIXTURES = Pathname(__dir__).join("fixtures").expand_path

  def test_current_repository_manifests_pass
    assert_empty PublicManifestValidator.validate(ROOT.join("plugins/flightdeck"))
  end

  def test_minimal_valid_plugin_passes
    with_fixture do |plugin_root|
      assert_empty PublicManifestValidator.validate(plugin_root)
    end
  end

  def test_rejects_invalid_semver
    assert_fixture_error("invalid-semver.json", ".codex-plugin/plugin.json", "strict SemVer")
  end

  def test_rejects_missing_required_plugin_fields
    assert_fixture_error("missing-required.json", ".codex-plugin/plugin.json", "author must be an object")
  end

  def test_rejects_too_many_or_too_long_default_prompts
    assert_fixture_error("too-many-prompts.json", ".codex-plugin/plugin.json", "at most 3 entries")
    assert_fixture_error("too-long-prompt.json", ".codex-plugin/plugin.json", "exceeds 128 characters")
  end

  def test_rejects_missing_declared_paths
    assert_fixture_error("missing-path.json", ".codex-plugin/plugin.json", "points to a missing file")
  end

  def test_rejects_invalid_optional_contact_url_and_color_fields
    errors = fixture_errors("invalid-contact-and-interface.json", ".codex-plugin/plugin.json")
    assert_includes errors, "plugin.json author email must be a non-empty string"
    assert_includes errors, "plugin.json author url must be an absolute https URL"
    assert_includes errors, "plugin.json interface websiteURL must be an absolute https URL"
    assert_includes errors, "plugin.json interface privacyPolicyURL must be an absolute https URL"
    assert_includes errors, "plugin.json interface termsOfServiceURL must be an absolute https URL"
    assert_includes errors, "plugin.json interface brandColor must use #RRGGBB"
  end

  def test_rejects_unknown_skill_frontmatter_keys
    assert_fixture_error("unknown-key.SKILL.md", "skills/example-skill/SKILL.md", "unsupported key `owner`")
  end

  def test_rejects_skill_name_directory_mismatch
    assert_fixture_error("name-mismatch.SKILL.md", "skills/example-skill/SKILL.md", "name must match its directory")
  end

  def test_rejects_invalid_agent_yaml
    assert_fixture_error("invalid-openai.yaml.fixture", "skills/example-skill/agents/openai.yaml", "must be valid safe YAML")
  end

  private

  def assert_fixture_error(fixture_name, destination, expected)
    errors = fixture_errors(fixture_name, destination)
    assert errors.any? { |error| error.include?(expected) }, "expected #{expected.inspect} in #{errors.inspect}"
  end

  def fixture_errors(fixture_name, destination)
    with_fixture do |plugin_root|
      FileUtils.cp(FIXTURES.join("invalid", fixture_name), plugin_root.join(destination))
      return PublicManifestValidator.validate(plugin_root)
    end
  end

  def with_fixture
    Dir.mktmpdir("flightdeck-public-manifest-") do |directory|
      plugin_root = Pathname(directory).join("sample-plugin")
      FileUtils.mkdir_p(plugin_root)
      source = FIXTURES.join("valid-plugin")
      FileUtils.cp_r(source.children, plugin_root)
      yield plugin_root
    end
  end
end
