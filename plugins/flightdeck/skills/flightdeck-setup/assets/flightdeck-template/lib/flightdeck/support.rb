# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "time"
require "timeout"
require "yaml"

module Flightdeck
  class Error < StandardError; end
  class UsageError < Error; end
  class ConfigurationError < Error; end
  class ValidationError < Error; end

  module Support
    module_function

    SLUG = /\A[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?\z/
    IDENTIFIER = /\A[a-z0-9]+(?:[a-z0-9._-]*[a-z0-9])?\z/
    DIRECTORY = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    def stringify(value, ancestors = {})
      case value
      when Hash
        with_acyclic_container(value, ancestors) do
          value.each_with_object({}) do |(key, item), out|
            out[key.to_s] = stringify(item, ancestors)
          end
        end
      when Array
        with_acyclic_container(value, ancestors) do
          value.map { |item| stringify(item, ancestors) }
        end
      else value
      end
    end

    def with_acyclic_container(value, ancestors)
      identity = value.object_id
      raise ValidationError, "structured data contains a recursive alias" if ancestors[identity]

      ancestors[identity] = true
      yield
    ensure
      ancestors.delete(identity) if identity
    end

    def safe_yaml(text, source: "YAML", aliases: false)
      stringify(
        YAML.safe_load(
          text,
          permitted_classes: [Date, Time],
          permitted_symbols: [],
          aliases: aliases
        ) || {}
      )
    rescue Psych::Exception => e
      raise ValidationError, "#{source} is invalid: #{e.message}"
    end

    def load_data(path, aliases: false)
      content = File.read(path, encoding: "UTF-8")
      value = if File.extname(path).downcase == ".json"
                JSON.parse(content)
              else
                safe_yaml(content, source: path, aliases: aliases)
              end
      stringify(value)
    rescue Errno::ENOENT
      raise ValidationError, "file does not exist: #{path}"
    rescue JSON::ParserError => e
      raise ValidationError, "#{path} is invalid JSON: #{e.message}"
    end

    def atomic_write(path, content)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory)
      temporary = Tempfile.new([".flightdeck-", ".tmp"], directory, encoding: "UTF-8")
      begin
        temporary.write(content)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close! if temporary
      end
    end

    def atomic_yaml(path, value)
      atomic_write(path, YAML.dump(value))
    end

    def contained_path(root, value, label: "path")
      expanded_root = File.expand_path(root)
      expanded = File.expand_path(value.to_s, expanded_root)
      prefix = "#{expanded_root}#{File::SEPARATOR}"
      unless expanded == expanded_root || expanded.start_with?(prefix)
        raise ConfigurationError, "#{label} escapes the Hub root: #{value}"
      end

      project = lambda do |path|
        existing = path
        suffix = []
        until File.exist?(existing) || File.symlink?(existing)
          parent = File.dirname(existing)
          break if parent == existing

          suffix.unshift(File.basename(existing))
          existing = parent
        end
        File.expand_path(File.join(File.realpath(existing), *suffix))
      end
      real_root = project.call(expanded_root)
      real_existing = project.call(expanded)
      real_prefix = "#{real_root}#{File::SEPARATOR}"
      unless real_existing == real_root || real_existing.start_with?(real_prefix)
        raise ConfigurationError, "#{label} resolves outside the Hub root: #{value}"
      end
      expanded
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise ConfigurationError, "#{label} cannot be resolved safely: #{e.message}"
    end

    def relative_path(root, path)
      root_path = File.exist?(root) ? File.realpath(root) : File.expand_path(root)
      value_path = File.exist?(path) ? File.realpath(path) : File.expand_path(path)
      Pathname.new(value_path).relative_path_from(Pathname.new(root_path)).to_s
    rescue ArgumentError, Errno::ENOENT, Errno::ELOOP
      File.expand_path(path)
    end

    def present?(value)
      !(value.nil? || (value.respond_to?(:empty?) && value.empty?))
    end

    def dig_path(value, dotted)
      dotted.to_s.split(".").reduce(value) do |current, segment|
        return nil unless current.is_a?(Hash)

        current[segment]
      end
    end

    def deep_merge(left, right)
      return stringify(right) unless left.is_a?(Hash) && right.is_a?(Hash)

      stringify(left).merge(stringify(right)) do |_key, old_value, new_value|
        old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
      end
    end

    def validate_slug!(value, label: "slug")
      return value if SLUG.match?(value.to_s)

      raise UsageError, "#{label} must use lowercase hyphen-separated words"
    end

    def validate_identifier!(value, label: "identifier")
      return value if IDENTIFIER.match?(value.to_s)

      raise UsageError, "#{label} contains unsupported characters"
    end

    def validate_directory!(value, label: "directory")
      return value if DIRECTORY.match?(value.to_s) && !%w[. ..].include?(value.to_s)

      raise UsageError, "#{label} must be one safe directory-name segment"
    end

    def capture(*arguments, chdir:, timeout: 20, env: {})
      return ["", "working directory is unavailable", 127] unless File.directory?(chdir)

      output = error = nil
      status = nil
      Timeout.timeout(timeout) do
        output, error, process = Open3.capture3(
          { "LC_ALL" => "C", "GIT_OPTIONAL_LOCKS" => "0" }.merge(env),
          *arguments,
          chdir: chdir
        )
        status = process.exitstatus
      end
      [output.to_s.strip, error.to_s.strip, status]
    rescue Timeout::Error
      ["", "command timed out after #{timeout} seconds", 124]
    rescue SystemCallError => e
      ["", "command could not start: #{e.class}", 127]
    end
  end
end
