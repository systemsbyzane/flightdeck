# frozen_string_literal: true

require_relative "workflow"

module Flightdeck
  class TaskStore
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def create(type:, slug:, title:, outcome:, workload: nil)
      Support.validate_slug!(slug, label: "task slug")
      Support.validate_identifier!(type, label: "task type")
      raise UsageError, "--title cannot be blank" unless Support.present?(title.to_s.strip)
      raise UsageError, "--outcome cannot be blank" unless Support.present?(outcome.to_s.strip)

      workflow = Workflow.from_config(config, type)
      workload = workflow.resolve_workload(workload)
      raise ValidationError, "unknown workload: #{workload}" unless config.workload(workload)
      path = task_path(slug)
      raise ValidationError, "task already exists: #{slug}" if File.exist?(task_dir(slug)) || File.exist?(path)

      now = Time.now.utc.iso8601
      task = Support.deep_merge(workflow.task_defaults, {
        "api_version" => "flightdeck.dev/v1alpha1",
        "kind" => "TaskRecord",
        "schema" => "hub/schemas/task.schema.json",
        "metadata" => {
          "id" => slug,
          "title" => title.to_s.strip,
          "created_at" => now,
          "updated_at" => now
        },
        "spec" => {
          "type" => type,
          "workload_id" => workload,
          "outcome" => {
            "description" => outcome.to_s.strip,
            "success_criteria" => []
          },
          "scope" => { "targets" => [] },
          "authorization" => { "actions" => [] }
        }.compact,
        "status" => {
          "state" => workflow.initial_state,
          "history" => [
            { "at" => now, "event" => "created", "from" => nil, "to" => workflow.initial_state }
          ]
        }
      })

      errors = validate_object(task, expected_slug: slug)
      raise ValidationError, errors.join("; ") unless errors.empty?

      FileUtils.mkdir_p(config.task_dir)
      Dir.mkdir(task_dir(slug))
      begin
        Support.atomic_yaml(path, task)
      rescue StandardError
        Dir.rmdir(task_dir(slug)) if Dir.exist?(task_dir(slug)) && Dir.empty?(task_dir(slug))
        raise
      end
      task
    end

    def fetch(slug)
      Support.validate_slug!(slug, label: "task slug")
      path = task_path(slug)
      raise ValidationError, "task does not exist: #{slug}" unless File.file?(path)

      task = Support.load_data(path)
      raise ValidationError, "task #{slug} must contain a mapping" unless task.is_a?(Hash)

      task
    end

    def transition(slug:, state:, note: nil)
      Support.validate_identifier!(state, label: "state")
      path = task_path(slug)
      lock_path = File.join(task_dir(slug), ".lock")
      task = nil

      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        task = fetch(slug)
        existing_errors = validate_object(task, expected_slug: slug)
        raise ValidationError, existing_errors.join("; ") unless existing_errors.empty?

        workflow = Workflow.from_config(config, task.dig("spec", "type"))
        current_state = task.dig("status", "state")
        workflow.validate_transition!(current_state, state)
        workflow.validate_gates!(task, from: current_state, to: state)
        now = Time.now.utc.iso8601
        task["status"]["history"] ||= []
        task["status"]["history"] << {
          "at" => now,
          "event" => "transitioned",
          "from" => current_state,
          "to" => state,
          "note" => Support.present?(note.to_s.strip) ? note.to_s.strip : nil
        }.compact
        task["status"]["state"] = state
        task["metadata"]["updated_at"] = now
        errors = validate_object(task, expected_slug: slug)
        raise ValidationError, errors.join("; ") unless errors.empty?

        Support.atomic_yaml(path, task)
      end
      task
    rescue Errno::ENOENT
      raise ValidationError, "task does not exist: #{slug}"
    end

    def validate(slug)
      validate_object(fetch(slug), expected_slug: slug)
    end

    def all
      return [] unless Dir.exist?(config.task_dir)

      Dir.glob(File.join(config.task_dir, "*", "task.yaml")).sort.filter_map do |path|
        task = Support.load_data(path)
        task if task.is_a?(Hash)
      rescue ValidationError => e
        { "metadata" => { "id" => File.basename(File.dirname(path)) }, "invalid" => e.message, "path" => path }
      end
    end

    def task_path(slug)
      File.join(task_dir(slug), "task.yaml")
    end

    private

    def task_dir(slug)
      Support.contained_path(config.task_dir, slug.to_s, label: "task slug")
    end

    def validate_object(task, expected_slug: nil)
      errors = []
      unless task.is_a?(Hash)
        return ["task must contain a mapping"]
      end

      %w[api_version kind metadata spec status].each do |field|
        errors << "missing required field #{field}" unless Support.present?(task[field])
      end
      errors << "api_version must be flightdeck.dev/v1alpha1" unless task["api_version"] == "flightdeck.dev/v1alpha1"
      errors << "kind must be TaskRecord" unless task["kind"] == "TaskRecord"
      %w[metadata spec status].each do |field|
        errors << "#{field} must be a mapping" unless task[field].is_a?(Hash)
      end
      return errors unless %w[metadata spec status].all? { |field| task[field].is_a?(Hash) }

      %w[metadata.id metadata.title metadata.created_at metadata.updated_at spec.type spec.outcome.description status.state status.history].each do |field|
        errors << "missing required field #{field}" unless Support.present?(Support.dig_path(task, field))
      end
      task_id = task.dig("metadata", "id")
      errors << "metadata.id does not match task directory" if expected_slug && task_id != expected_slug
      history = task.dig("status", "history")
      errors << "status.history must be a list" unless history.is_a?(Array)
      outcome = task["spec"]["outcome"]
      errors << "spec.outcome must be a mapping" unless outcome.is_a?(Hash)
      errors << "spec.outcome.success_criteria must be a list" unless outcome.is_a?(Hash) && outcome["success_criteria"].is_a?(Array)
      scope = task["spec"]["scope"]
      errors << "spec.scope must be a mapping" unless scope.is_a?(Hash)
      errors << "spec.scope.targets must be a list" unless scope.is_a?(Hash) && scope["targets"].is_a?(Array)
      authorization = task["spec"]["authorization"]
      errors << "spec.authorization must be a mapping" unless authorization.is_a?(Hash)
      errors << "spec.authorization.actions must be a list" unless authorization.is_a?(Hash) && authorization["actions"].is_a?(Array)
      errors << "spec.execution must be a mapping" unless task["spec"]["execution"].is_a?(Hash)
      errors << "spec.policies must be a mapping" unless task["spec"]["policies"].is_a?(Hash)
      validate_object_array(scope && scope["targets"], "spec.scope.targets", %w[kind name], errors)
      validate_object_array(authorization && authorization["actions"], "spec.authorization.actions", %w[action policy], errors)
      {
        "status.units" => %w[id role context state],
        "status.evidence" => %w[id category description state recorded_at],
        "status.checks" => %w[id status],
        "status.approvals" => %w[gate status],
        "status.risks" => %w[id description severity status],
        "status.blockers" => %w[id description status]
      }.each do |field, required_keys|
        key = field.split(".").last
        value = task["status"][key]
        next if value.nil? && !%w[evidence blockers].include?(key)

        validate_object_array(value, field, required_keys, errors)
      end
      %w[metadata.created_at metadata.updated_at].each do |field|
        begin
          Time.iso8601(Support.dig_path(task, field).to_s)
        rescue ArgumentError
          errors << "#{field} must be an ISO 8601 timestamp"
        end
      end
      workload = task.dig("spec", "workload_id")
      if workload && !config.workload(workload)
        errors << "unknown workload #{workload}"
      end

      begin
        workflow = Workflow.from_config(config, task.dig("spec", "type"))
        state = task.dig("status", "state")
        errors << "unknown state #{state}" unless workflow.states.include?(state.to_s)
        workflow.required_fields.each do |field|
          errors << "missing workflow-required field #{field}" unless Support.present?(Support.dig_path(task, field))
        end
        validate_history(task, workflow, errors)
      rescue ValidationError => e
        errors << e.message
      end
      errors
    end

    def validate_history(task, workflow, errors)
      history = task.dig("status", "history")
      return unless history.is_a?(Array)

      previous = nil
      history.each_with_index do |event, index|
        unless event.is_a?(Hash)
          errors << "history entry #{index + 1} must be a mapping"
          next
        end
        %w[at event from to].each do |key|
          errors << "history entry #{index + 1} is missing #{key}" unless event.key?(key)
        end
        begin
          Time.iso8601(event["at"].to_s)
        rescue ArgumentError
          errors << "history entry #{index + 1} at must be an ISO 8601 timestamp"
        end
        to = event["to"]
        errors << "history entry #{index + 1} has unknown target state #{to}" if to && !workflow.states.include?(to.to_s)
        if index.zero?
          errors << "first history entry must enter initial state #{workflow.initial_state}" unless to.to_s == workflow.initial_state
        elsif event["event"] == "transitioned"
          errors << "history entry #{index + 1} does not continue from prior state" unless event["from"].to_s == previous.to_s
          begin
            workflow.validate_transition!(event["from"], to)
          rescue ValidationError => e
            errors << "history entry #{index + 1}: #{e.message}"
          end
        end
        previous = to if to
      end
      current_state = task.dig("status", "state")
      if previous && current_state && previous.to_s != current_state.to_s
        errors << "current state does not match final history state"
      end
    end

    def validate_object_array(value, field, required_keys, errors)
      unless value.is_a?(Array)
        errors << "#{field} must be a list"
        return
      end

      value.each_with_index do |item, index|
        unless item.is_a?(Hash)
          errors << "#{field}[#{index}] must be a mapping"
          next
        end
        required_keys.each do |key|
          errors << "#{field}[#{index}] is missing #{key}" unless Support.present?(item[key])
        end
      end
    end
  end
end

