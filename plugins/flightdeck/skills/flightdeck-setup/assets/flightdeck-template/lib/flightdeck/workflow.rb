# frozen_string_literal: true

require_relative "support"

module Flightdeck
  class Workflow
    attr_reader :type, :path, :data

    def initialize(type:, path:)
      @type = type.to_s
      @path = path
      @data = Support.load_data(path)
      raise ValidationError, "workflow #{@type} must contain a mapping" unless @data.is_a?(Hash)

      validate_definition!
    end

    def self.from_config(config, type)
      path = config.workflow_path(type)
      raise ValidationError, "unknown task type: #{type}" unless path
      raise ValidationError, "workflow file does not exist: #{path}" unless File.file?(path)

      new(type: type, path: path)
    end

    def states
      data.fetch("states", {}).keys.map(&:to_s)
    end

    def initial_state
      data.fetch("initial_state").to_s
    end

    def transitions_from(state)
      Array(data.fetch("transitions", {})[state.to_s]).map(&:to_s)
    end

    def task_defaults
      value = data.fetch("task_defaults", {})
      value.is_a?(Hash) ? value : {}
    end

    def required_fields
      Array(data["required_fields"]).map(&:to_s)
    end

    def supported_workloads
      Array(data["supported_workloads"]).map(&:to_s)
    end

    def resolve_workload(requested)
      value = requested.to_s if requested
      unless Support.present?(value)
        default = task_defaults.dig("spec", "workload_id")
        return default.to_s if Support.present?(default)
        return supported_workloads.first if supported_workloads.one?

        raise ValidationError, "--workload is required for #{type}"
      end
      if supported_workloads.any? && !supported_workloads.include?(value)
        raise ValidationError, "workload #{value} is not supported by #{type}"
      end
      value
    end

    def validate_transition!(from, to)
      raise ValidationError, "unknown state #{to.inspect} for #{type}" unless states.include?(to.to_s)
      return if transitions_from(from).include?(to.to_s)

      raise ValidationError, "cannot transition #{type} from #{from.inspect} to #{to.inspect}"
    end

    def validate_gates!(task, from:, to:)
      gate_ids = state_gates(from, "exit_gates") + state_gates(to, "entry_gates")
      gate_ids.uniq.each do |gate_id|
        gate = data.fetch("gates", {})[gate_id]
        raise ValidationError, "workflow #{type} references undefined gate #{gate_id}" unless gate.is_a?(Hash)

        missing = Array(gate["required_fields"]).reject do |field|
          Support.present?(Support.dig_path(task, field))
        end
        next if missing.empty?

        raise ValidationError, "gate #{gate_id} blocks transition; missing: #{missing.join(', ')}"
      end
    end

    private

    def state_gates(state, key)
      definition = data.fetch("states", {})[state.to_s]
      definition.is_a?(Hash) ? Array(definition[key]).map(&:to_s) : []
    end

    def validate_definition!
      raise ValidationError, "workflow #{type} has no states" if states.empty?
      raise ValidationError, "workflow #{type} has invalid initial state" unless states.include?(initial_state)

      states.each do |state|
        unknown = transitions_from(state) - states
        raise ValidationError, "#{state} transitions to unknown states: #{unknown.join(', ')}" if unknown.any?
        %w[entry_gates exit_gates].each do |key|
          state_gates(state, key).each do |gate|
            raise ValidationError, "#{state} references undefined gate #{gate}" unless data.fetch("gates", {})[gate].is_a?(Hash)
          end
        end
      end
    end
  end
end

