PYTHON ?= python3
RUBY ?= ruby

PLUGIN := plugins/flightdeck
SETUP := $(PLUGIN)/skills/flightdeck-setup
TEMPLATE := $(SETUP)/assets/flightdeck-template
CODEX_SKILLS_ROOT ?= $(shell $(PYTHON) -c 'from pathlib import Path; print(Path.home()/".codex"/"skills")')
PLUGIN_VALIDATOR := $(CODEX_SKILLS_ROOT)/.system/plugin-creator/scripts/validate_plugin.py
SKILL_VALIDATOR := $(CODEX_SKILLS_ROOT)/.system/skill-creator/scripts/quick_validate.py
LOCAL_EVIDENCE ?= $(CURDIR)/.flightdeck-local/validation/current
GENERATED_HUB ?= $(LOCAL_EVIDENCE)/generated-flightdeck
SOURCE_HUB ?=
SOURCE_HUB_SKILL ?=
SOURCE_STIG_SKILL ?=
RUNTIME_ACCEPTANCE ?=
UPGRADE_ACCEPTANCE ?=
PRIVATE_NEUTRALIZATION_MAP ?=
SEMANTIC_OVERALL_EXPECTED := False
ifneq ($(strip $(RUNTIME_ACCEPTANCE)),)
ifneq ($(strip $(UPGRADE_ACCEPTANCE)),)
SEMANTIC_OVERALL_EXPECTED := True
endif
endif

.PHONY: \
	acceptance debranding fresh-hub full-local links marketplace-validate \
	mission-acceptance mission-stress mission-test public-validate \
	plugin-validate preflight process-inventory process-inventory-source \
	private-neutralization-required release-validate ruby-tests \
	semantic-parity-local skills-validate structured \
	test validate

test: ruby-tests
	$(PYTHON) -m unittest discover -s $(SETUP)/tests -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s $(PLUGIN)/skills/flightdeck-artifacts/tests -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s $(PLUGIN)/skills/flightdeck-stig/tests -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s $(PLUGIN)/skills/flightdeck-upgrade/tests -p 'test_*.py' -v

plugin-validate:
	$(PYTHON) $(PLUGIN_VALIDATOR) $(PLUGIN)

marketplace-validate:
	$(PYTHON) -c 'import json, pathlib; p=pathlib.Path(".agents/plugins/marketplace.json"); d=json.loads(p.read_text()); e=d["plugins"][0]; assert d["name"]=="flightdeck-team"; assert e["name"]=="flightdeck"; assert e["source"]=={"source":"local","path":"./plugins/flightdeck"}; assert e["policy"]["installation"] in {"NOT_AVAILABLE","AVAILABLE","INSTALLED_BY_DEFAULT"}; assert e["policy"]["authentication"] in {"ON_INSTALL","ON_USE"}; assert isinstance(e["category"],str) and e["category"]'

skills-validate:
	@for skill in $(PLUGIN)/skills/*; do \
		test ! -f "$$skill/SKILL.md" || $(PYTHON) $(SKILL_VALIDATOR) "$$skill" || exit 1; \
	done

structured:
	$(PYTHON) $(SETUP)/scripts/validate_structured.py .

ruby-tests:
	$(RUBY) -I$(TEMPLATE)/lib $(TEMPLATE)/tests/flightdeck_test.rb

preflight:
	$(PYTHON) $(SETUP)/scripts/preflight.py --json

links:
	$(PYTHON) $(SETUP)/scripts/validate_links.py

debranding:
	$(PYTHON) $(SETUP)/scripts/scan_debranding.py . \
		$(if $(PRIVATE_NEUTRALIZATION_MAP),--private-neutralization-map "$(PRIVATE_NEUTRALIZATION_MAP)")

fresh-hub:
	$(PYTHON) $(SETUP)/scripts/bootstrap.py --target "$(GENERATED_HUB)" --apply --json

acceptance:
	@mkdir -p "$(LOCAL_EVIDENCE)"
	$(PYTHON) $(SETUP)/scripts/acceptance_harness.py \
		--json "$(LOCAL_EVIDENCE)/acceptance.json"

mission-test:
	$(PYTHON) -m unittest discover -s $(SETUP)/tests -p 'test_mission_acceptance.py' -v

mission-acceptance: acceptance

mission-stress:
	PYTHONPATH="$(SETUP)/tests" $(PYTHON) -m unittest -v \
		test_mission_acceptance.MissionAcceptanceTest.test_stress_100_missions_16_children_and_10000_replayed_snapshots

process-inventory:
	@mkdir -p "$(LOCAL_EVIDENCE)"
	$(PYTHON) $(SETUP)/scripts/process_inventory.py \
		--candidate "$(CURDIR)/$(TEMPLATE)" \
		--plugin "$(CURDIR)/$(PLUGIN)" \
		--json "$(LOCAL_EVIDENCE)/process-inventory.json"

process-inventory-source:
	@test -n "$(SOURCE_HUB)" || { echo "SOURCE_HUB is required"; exit 2; }
	@mkdir -p "$(LOCAL_EVIDENCE)"
	$(PYTHON) $(SETUP)/scripts/process_inventory.py \
		--source "$(SOURCE_HUB)" \
		--candidate "$(CURDIR)/$(TEMPLATE)" \
		--plugin "$(CURDIR)/$(PLUGIN)" \
		--json "$(LOCAL_EVIDENCE)/process-inventory-source.json"

validate: plugin-validate marketplace-validate skills-validate structured test preflight links debranding fresh-hub acceptance process-inventory

public-validate: marketplace-validate structured test preflight links debranding fresh-hub acceptance process-inventory

semantic-parity-local:
	@test -n "$(SOURCE_HUB)" || { echo "SOURCE_HUB is required"; exit 2; }
	@mkdir -p "$(LOCAL_EVIDENCE)"
	@set +e; \
	$(PYTHON) $(SETUP)/scripts/compare_hubs.py \
		--source "$(SOURCE_HUB)" \
		--candidate "$(CURDIR)/$(TEMPLATE)" \
		--plugin "$(CURDIR)/$(PLUGIN)" \
		$(if $(SOURCE_HUB_SKILL),--source-hub-skill "$(SOURCE_HUB_SKILL)") \
		$(if $(SOURCE_STIG_SKILL),--source-stig-skill "$(SOURCE_STIG_SKILL)") \
		$(if $(RUNTIME_ACCEPTANCE),--runtime-acceptance "$(RUNTIME_ACCEPTANCE)") \
		$(if $(UPGRADE_ACCEPTANCE),--upgrade-acceptance "$(UPGRADE_ACCEPTANCE)") \
		$(if $(PRIVATE_NEUTRALIZATION_MAP),--private-neutralization-map "$(PRIVATE_NEUTRALIZATION_MAP)") \
		--json "$(LOCAL_EVIDENCE)/semantic-parity.json" \
		--summary "$(LOCAL_EVIDENCE)/semantic-parity.md"; \
	status=$$?; \
	set -e; \
	test $$status -eq 0 -o $$status -eq 1
	$(PYTHON) -c 'import json, pathlib; d=json.loads(pathlib.Path("$(LOCAL_EVIDENCE)/semantic-parity.json").read_text()); assert d["claim"]["locally_testable_mandatory_surfaces_pass"] is True; assert d["claim"]["overall_1_to_1_functional_parity"] is $(SEMANTIC_OVERALL_EXPECTED)'

full-local: validate process-inventory-source semantic-parity-local

private-neutralization-required:
	@test -n "$(PRIVATE_NEUTRALIZATION_MAP)" || { \
		echo "PRIVATE_NEUTRALIZATION_MAP is required for source-backed release validation"; \
		exit 2; \
	}
	@test -f "$(PRIVATE_NEUTRALIZATION_MAP)" || { \
		echo "PRIVATE_NEUTRALIZATION_MAP must name an existing ignored JSON file"; \
		exit 2; \
	}
	@git check-ignore -q "$(PRIVATE_NEUTRALIZATION_MAP)" || { \
		echo "PRIVATE_NEUTRALIZATION_MAP must be ignored by Git"; \
		exit 2; \
	}

release-validate: private-neutralization-required full-local
