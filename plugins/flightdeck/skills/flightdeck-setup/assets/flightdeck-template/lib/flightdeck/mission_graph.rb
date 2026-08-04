# frozen_string_literal: true

require_relative "support"

module Flightdeck
  class MissionGraph
    NODE_STATES = %w[
      planned dispatch_pending dispatch_unknown awaiting_handoff running needs_approval blocked
      failed_validation runtime_failure review_ready stale cancelled complete
    ].freeze
    OBSERVED_STATES = %w[
      running needs_approval blocked failed_validation runtime_failure review_ready
      cancelled notLoaded
    ].freeze
    TERMINAL_STATES = %w[cancelled complete].freeze

    attr_reader :nodes

    def initialize(nodes)
      @nodes = Array(nodes)
    end

    def validate
      errors = []
      ids = {}
      nodes.each_with_index do |node, index|
        unless node.is_a?(Hash)
          errors << "spec.graph.nodes[#{index}] must be a mapping"
          next
        end
        id = node["id"].to_s
        errors << "spec.graph.nodes[#{index}].id is required" unless Support.present?(id)
        errors << "duplicate mission node #{id}" if Support.present?(id) && ids[id]
        ids[id] = true if Support.present?(id)
        errors << "node #{id} has unknown state #{node['observed_state']}" unless NODE_STATES.include?(node["observed_state"].to_s)
        errors << "node #{id} required must be boolean" unless [true, false].include?(node["required"])
        errors << "node #{id} dependencies must be a list" unless node["dependencies"].is_a?(Array)
      end
      nodes.each do |node|
        next unless node.is_a?(Hash) && node["dependencies"].is_a?(Array)

        node["dependencies"].each do |dependency|
          errors << "node #{node['id']} depends on unknown node #{dependency}" unless ids[dependency.to_s]
          errors << "node #{node['id']} cannot depend on itself" if dependency.to_s == node["id"].to_s
          producer = nodes.find { |item| item.is_a?(Hash) && item["id"].to_s == dependency.to_s }
          if producer && producer["authorization_boundary"] != node["authorization_boundary"]
            errors << "dependency authorization boundary mismatch for #{producer['id']} -> #{node['id']}"
          end
        end
      end
      cycle = cycle_path
      errors << "mission graph contains a dependency cycle: #{cycle.join(' -> ')}" if cycle
      errors.concat(concurrent_writer_errors) unless cycle
      errors
    end

    def cycle_path
      by_id = nodes.filter_map { |node| [node["id"].to_s, node] if node.is_a?(Hash) }.to_h
      state = {}
      stack = []
      visit = lambda do |id|
        return nil if state[id] == :done
        if state[id] == :visiting
          start = stack.index(id) || 0
          return stack[start..] + [id]
        end

        state[id] = :visiting
        stack << id
        Array(by_id.dig(id, "dependencies")).each do |dependency|
          found = visit.call(dependency.to_s)
          return found if found
        end
        stack.pop
        state[id] = :done
        nil
      end
      by_id.each_key do |id|
        found = visit.call(id)
        return found if found
      end
      nil
    end

    def required_nodes
      nodes.select { |node| node["required"] == true }
    end

    def concurrent_writer_errors
      writers = nodes.select do |node|
        node.is_a?(Hash) && node["execution_mode"] == "local" && node["access_mode"] == "write"
      end
      writers.combination(2).filter_map do |left, right|
        next unless left["project_path_digest"] == right["project_path_digest"]
        next if depends_on?(left["id"], right["id"]) || depends_on?(right["id"], left["id"])

        "concurrent local writer conflict for #{left['id']} and #{right['id']}"
      end
    end

    def depends_on?(node_id, dependency_id, seen = {})
      return false if seen[node_id]
      seen[node_id] = true
      node = nodes.find { |item| item["id"] == node_id }
      return false unless node
      return true if Array(node["dependencies"]).include?(dependency_id)

      Array(node["dependencies"]).any? { |id| depends_on?(id, dependency_id, seen) }
    end

    def fan_in_ready?
      !required_nodes.empty? && required_nodes.all? do |node|
        %w[review_ready complete].include?(node["observed_state"]) &&
          node["validation_status"] == "passed" && !Array(node["output_refs"]).empty?
      end
    end

    def dependencies_ready?(node)
      by_id = nodes.to_h { |item| [item["id"], item] }
      Array(node["dependencies"]).all? do |id|
        dependency = by_id[id]
        dependency && %w[review_ready complete].include?(dependency["observed_state"]) &&
          dependency["validation_status"] == "passed" && !Array(dependency["output_refs"]).empty?
      end
    end

    def derive_state(current_state: nil)
      return "complete" if current_state == "complete"

      required = required_nodes
      return "planned" if required.empty? || required.all? { |node| node["observed_state"] == "planned" }
      return "failed_validation" if required.any? { |node| node["observed_state"] == "failed_validation" }
      return "needs_approval" if required.any? { |node| node["observed_state"] == "needs_approval" }
      return "blocked" if required.any? { |node| node["observed_state"] == "blocked" }
      return "runtime_failure" if required.any? { |node| node["observed_state"] == "runtime_failure" }
      return "dispatch_unknown" if required.any? { |node| node["observed_state"] == "dispatch_unknown" }
      return "stale" if required.any? { |node| node["observed_state"] == "stale" }
      return "cancelled" if required.all? { |node| node["observed_state"] == "cancelled" }
      return "review_ready" if fan_in_ready?
      return "dispatch_pending" if required.any? { |node| node["observed_state"] == "dispatch_pending" }

      "running"
    end
  end
end
