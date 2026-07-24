.PHONY: test validate doctor

test:
	ruby -Ilib tests/flightdeck_test.rb

doctor:
	bin/flightdeck doctor --json

validate: test
	ruby -c bin/flightdeck
	@for file in lib/flightdeck/*.rb; do ruby -c "$$file" >/dev/null || exit 1; done
	@ruby -e 'require "json"; require "yaml"; ARGV.each { |p| File.extname(p) == ".json" ? JSON.parse(File.read(p)) : YAML.safe_load(File.read(p), aliases: false) }' $$(find . \
		-path ./.git -prune -o \
		-path ./.flightdeck-local -prune -o \
		-path ./charts -prune -o \
		-path ./compliance -prune -o \
		-path ./development -prune -o \
		-path ./environments -prune -o \
		-path ./handoffs -prune -o \
		-path ./operations -prune -o \
		-path ./patching -prune -o \
		-path ./research -prune -o \
		-path ./hub/cache -prune -o \
		-path ./hub/reports -prune -o \
		-path ./hub/state -prune -o \
		-path ./hub/tasks -prune -o \
		-path ./hub/tmp -prune -o \
		-type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print)
	@echo "Flightdeck validation passed."
