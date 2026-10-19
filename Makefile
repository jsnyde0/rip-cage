.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local

BASH_SCRIPTS := rc cli/*.sh cli/lib/*.sh cage/init/init-rip-cage.sh cage/floor/floor-probe.sh cage/substrate/bd-wrapper.sh tests/_scratch-cage-lib.sh tests/run-host.sh tests/_host-sandbox-lib.sh tests/run-one.sh
# Every test file is linted by glob, so a new one cannot land unlinted.
TEST_SCRIPTS := $(wildcard tests/test-*.sh)

.PHONY: help install uninstall build test lint

help: ## Show available targets
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

install: ## Symlink rc to $(PREFIX)/bin/rc (default PREFIX=~/.local)
	@mkdir -p "$(PREFIX)/bin"
	@ln -sf "$(CURDIR)/rc" "$(PREFIX)/bin/rc"
	@echo "Installed: $(PREFIX)/bin/rc -> $(CURDIR)/rc"

uninstall: ## Remove the rc symlink from $(PREFIX)/bin
	@rm -f "$(PREFIX)/bin/rc"
	@echo "Removed: $(PREFIX)/bin/rc"

build: ## Build the rip-cage Docker image
	./rc build

# SC2329 ("function never invoked") is off for test files only: their trap and callback helpers are invoked indirectly.
lint: ## Run the bash-3.2 compat gate, then shellcheck (pinned docker image — matches CI)
	bash tests/test-bash32-constructs.sh
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 -x $(BASH_SCRIPTS)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 -x -e SC2329 $(TEST_SCRIPTS)

test: ## Run host-only test scripts (no container required)
	bash tests/test-prerequisites.sh
	bash tests/test-docker-daemon-hang.sh
	bash tests/test-rc-commands.sh
	bash tests/test-json-output.sh
