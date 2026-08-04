#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "uri"
require "yaml"

module PublicManifestValidator
  SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
  PLUGIN_NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  MAX_SKILL_NAME_LENGTH = 64
  MAX_SKILL_DESCRIPTION_LENGTH = 1_024
  MAX_DEFAULT_PROMPTS = 3
  MAX_DEFAULT_PROMPT_LENGTH = 128
  HEX_COLOR = /\A#[0-9A-Fa-f]{6}\z/

  PLUGIN_KEYS = %w[
    id name version description skills apps mcpServers interface author homepage
    repository license keywords
  ].freeze
  INTERFACE_KEYS = %w[
    displayName shortDescription longDescription developerName category
    capabilities websiteURL privacyPolicyURL termsOfServiceURL brandColor
    composerIcon logo logoDark screenshots defaultPrompt default_prompt
  ].freeze
  SKILL_FRONTMATTER_KEYS = %w[name description license allowed-tools metadata].freeze

  module_function

  def validate(plugin_root)
    root = Pathname(plugin_root).expand_path.cleanpath
    errors = []
    manifest = load_json_object(root.join(".codex-plugin/plugin.json"), "plugin.json", errors)
    return errors unless manifest

    reject_unknown_keys(manifest, PLUGIN_KEYS, "plugin.json", errors)
    reject_todo_markers(manifest, "plugin.json", errors)

    name = require_string(manifest, "name", "plugin.json", errors)
    if name
      errors << "plugin.json name must use lowercase hyphen-case" unless PLUGIN_NAME.match?(name)
      errors << "plugin.json name must match plugin directory `#{root.basename}`" unless name == root.basename.to_s
    end

    version = require_string(manifest, "version", "plugin.json", errors)
    errors << "plugin.json version must be strict SemVer" if version && !SEMVER.match?(version)
    require_string(manifest, "description", "plugin.json", errors)

    author = require_hash(manifest, "author", "plugin.json", errors)
    if author
      require_string(author, "name", "plugin.json author", errors)
      validate_optional_string(author, "email", "plugin.json author", errors)
      validate_optional_https_url(author, "url", "plugin.json author", errors)
    end

    interface = require_hash(manifest, "interface", "plugin.json", errors)
    validate_interface(root, interface, errors) if interface

    validate_declared_path(root, root, manifest["skills"], "plugin.json skills", :directory, errors) if manifest.key?("skills")
    validate_declared_path(root, root, manifest["apps"], "plugin.json apps", :file, errors) if manifest.key?("apps")
    if manifest["mcpServers"].is_a?(String)
      validate_declared_path(root, root, manifest["mcpServers"], "plugin.json mcpServers", :file, errors)
    elsif manifest.key?("mcpServers") && !manifest["mcpServers"].is_a?(Hash)
      errors << "plugin.json mcpServers must be a relative path or object"
    end

    skills_root = declared_skills_root(root, manifest, errors)
    validate_skills(skills_root, errors) if skills_root&.directory?
    errors
  end

  def validate_interface(plugin_root, interface, errors)
    reject_unknown_keys(interface, INTERFACE_KEYS, "plugin.json interface", errors)
    %w[displayName shortDescription longDescription developerName category].each do |key|
      require_string(interface, key, "plugin.json interface", errors)
    end

    capabilities = interface["capabilities"]
    unless capabilities.is_a?(Array) && capabilities.all? { |item| item.is_a?(String) && !item.strip.empty? }
      errors << "plugin.json interface capabilities must be an array of non-empty strings"
    end

    %w[websiteURL privacyPolicyURL termsOfServiceURL].each do |key|
      validate_optional_https_url(interface, key, "plugin.json interface", errors)
    end
    brand_color = interface["brandColor"]
    if interface.key?("brandColor") && (!brand_color.is_a?(String) || !HEX_COLOR.match?(brand_color))
      errors << "plugin.json interface brandColor must use #RRGGBB"
    end

    prompt_keys = %w[defaultPrompt default_prompt].select { |key| interface.key?(key) }
    if prompt_keys.empty?
      errors << "plugin.json interface defaultPrompt is required"
    elsif prompt_keys.length > 1
      errors << "plugin.json interface must not declare both defaultPrompt and default_prompt"
    else
      prompts = interface[prompt_keys.first]
      unless prompts.is_a?(Array) && prompts.all? { |item| item.is_a?(String) && !item.strip.empty? }
        errors << "plugin.json interface defaultPrompt must be an array of non-empty strings"
      else
        errors << "plugin.json interface defaultPrompt must contain at most #{MAX_DEFAULT_PROMPTS} entries" if prompts.length > MAX_DEFAULT_PROMPTS
        prompts.each_with_index do |prompt, index|
          if prompt.length > MAX_DEFAULT_PROMPT_LENGTH
            errors << "plugin.json interface defaultPrompt[#{index}] exceeds #{MAX_DEFAULT_PROMPT_LENGTH} characters"
          end
        end
      end
    end

    %w[composerIcon logo logoDark].each do |key|
      next unless interface.key?(key)

      validate_declared_path(plugin_root, plugin_root, interface[key], "plugin.json interface #{key}", :file, errors)
    end
    screenshots = interface.fetch("screenshots", [])
    if !screenshots.is_a?(Array)
      errors << "plugin.json interface screenshots must be an array"
    else
      screenshots.each_with_index do |path, index|
        validate_declared_path(plugin_root, plugin_root, path, "plugin.json interface screenshots[#{index}]", :file, errors)
      end
    end
  end

  def declared_skills_root(plugin_root, manifest, errors)
    raw_path = manifest.fetch("skills", "./skills/")
    resolved = safe_relative_path(plugin_root, plugin_root, raw_path, "plugin.json skills", errors)
    resolved if resolved&.directory?
  end

  def validate_skills(skills_root, errors)
    skills_root.children.sort.each do |skill_root|
      next if skill_root.basename.to_s.start_with?(".") || !skill_root.directory?

      validate_skill(skill_root, errors)
    end
  end

  def validate_skill(skill_root, errors)
    label = "skill `#{skill_root.basename}`"
    skill_md = skill_root.join("SKILL.md")
    unless skill_md.file?
      errors << "#{label} is missing SKILL.md"
      return
    end

    frontmatter = parse_frontmatter(skill_md, label, errors)
    return unless frontmatter

    reject_unknown_keys(frontmatter, SKILL_FRONTMATTER_KEYS, "#{label} frontmatter", errors)
    name = require_string(frontmatter, "name", "#{label} frontmatter", errors)
    if name
      errors << "#{label} name must use lowercase hyphen-case" unless PLUGIN_NAME.match?(name)
      errors << "#{label} name exceeds #{MAX_SKILL_NAME_LENGTH} characters" if name.length > MAX_SKILL_NAME_LENGTH
      errors << "#{label} name must match its directory" unless name == skill_root.basename.to_s
    end
    description = require_string(frontmatter, "description", "#{label} frontmatter", errors)
    if description
      errors << "#{label} description exceeds #{MAX_SKILL_DESCRIPTION_LENGTH} characters" if description.length > MAX_SKILL_DESCRIPTION_LENGTH
      errors << "#{label} description must not contain angle brackets" if description.include?("<") || description.include?(">")
    end

    agent_yaml = skill_root.join("agents/openai.yaml")
    parse_yaml_mapping(agent_yaml, "#{label} agents/openai.yaml", errors) if agent_yaml.file?
  end

  def parse_frontmatter(path, label, errors)
    contents = path.read(encoding: "UTF-8")
    match = contents.match(/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/m)
    unless match
      errors << "#{label} must start with closed YAML frontmatter"
      return nil
    end
    parse_yaml_text(match[1], "#{label} frontmatter", errors)
  rescue SystemCallError, EncodingError => error
    errors << "#{label} could not be read: #{error.message}"
    nil
  end

  def parse_yaml_mapping(path, label, errors)
    parse_yaml_text(path.read(encoding: "UTF-8"), label, errors)
  rescue SystemCallError, EncodingError => error
    errors << "#{label} could not be read: #{error.message}"
    nil
  end

  def parse_yaml_text(text, label, errors)
    payload = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
    unless payload.is_a?(Hash)
      errors << "#{label} must contain a YAML mapping"
      return nil
    end
    payload
  rescue Psych::Exception => error
    errors << "#{label} must be valid safe YAML: #{error.message.lines.first.strip}"
    nil
  end

  def load_json_object(path, label, errors)
    payload = JSON.parse(path.read(encoding: "UTF-8"))
    unless payload.is_a?(Hash)
      errors << "#{label} must contain a JSON object"
      return nil
    end
    payload
  rescue Errno::ENOENT
    errors << "missing #{label}"
    nil
  rescue SystemCallError, EncodingError, JSON::ParserError => error
    errors << "#{label} must be readable valid JSON: #{error.message}"
    nil
  end

  def validate_declared_path(base, allowed_root, raw_path, label, kind, errors)
    resolved = safe_relative_path(base, allowed_root, raw_path, label, errors)
    return unless resolved

    valid = kind == :directory ? resolved.directory? : resolved.file?
    errors << "#{label} points to a missing #{kind}" unless valid
  end

  def safe_relative_path(base, allowed_root, raw_path, label, errors)
    unless raw_path.is_a?(String) && raw_path.start_with?("./") && !raw_path.include?("\\")
      errors << "#{label} must be a ./-relative path"
      return nil
    end

    root = allowed_root.expand_path.cleanpath
    candidate = base.join(raw_path).expand_path.cleanpath
    relative = candidate.relative_path_from(root).to_s
    if relative == ".." || relative.start_with?("../")
      errors << "#{label} must stay inside the plugin directory"
      return nil
    end

    if candidate.exist?
      real_relative = Pathname(candidate.realpath).relative_path_from(Pathname(root.realpath)).to_s
      if real_relative == ".." || real_relative.start_with?("../")
        errors << "#{label} must not escape through a symlink"
        return nil
      end
    end
    candidate
  rescue ArgumentError, Errno::ENOENT
    errors << "#{label} must stay inside the plugin directory"
    nil
  end

  def reject_unknown_keys(payload, allowed, label, errors)
    (payload.keys.map(&:to_s) - allowed).sort.each do |key|
      errors << "#{label} contains unsupported key `#{key}`"
    end
  end

  def require_string(payload, key, label, errors)
    value = payload[key]
    unless value.is_a?(String) && !value.strip.empty?
      errors << "#{label} #{key} must be a non-empty string"
      return nil
    end
    value.strip
  end

  def require_hash(payload, key, label, errors)
    value = payload[key]
    unless value.is_a?(Hash)
      errors << "#{label} #{key} must be an object"
      return nil
    end
    value
  end

  def validate_optional_string(payload, key, label, errors)
    return unless payload.key?(key)

    value = payload[key]
    errors << "#{label} #{key} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
  end

  def validate_optional_https_url(payload, key, label, errors)
    return unless payload.key?(key)

    value = payload[key]
    uri = URI.parse(value) if value.is_a?(String)
    valid = uri.is_a?(URI::HTTPS) && uri.scheme == "https" && uri.host && !uri.host.empty?
    errors << "#{label} #{key} must be an absolute https URL" unless valid
  rescue URI::InvalidURIError
    errors << "#{label} #{key} must be an absolute https URL"
  end

  def reject_todo_markers(value, label, errors)
    case value
    when String
      errors << "#{label} contains a [TODO: ...] placeholder" if value.include?("[TODO:")
    when Array
      value.each { |item| reject_todo_markers(item, label, errors) }
    when Hash
      value.each_value { |item| reject_todo_markers(item, label, errors) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  plugin_root = ARGV.fetch(0, "plugins/flightdeck")
  errors = PublicManifestValidator.validate(plugin_root)
  if errors.empty?
    puts "Public manifest validation passed: #{Pathname(plugin_root).expand_path}"
  else
    warn "Public manifest validation failed:"
    errors.each { |error| warn "- #{error}" }
    exit 1
  end
end
