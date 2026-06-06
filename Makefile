.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local

BASH_SCRIPTS := rc init-rip-cage.sh hooks/*.sh bd-wrapper.sh tests/test-prerequisites.sh tests/test-docker-daemon-hang.sh tests/test-manifest-schema.sh tests/test-manifest-tool.sh tests/test-manifest-egress.sh tests/test-manifest-shell.sh

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

lint: ## Run shellcheck on bash scripts (pinned docker image — matches CI)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 -x $(BASH_SCRIPTS)

test: ## Run host-only test scripts (no container required)
	bash tests/test-prerequisites.sh
	bash tests/test-docker-daemon-hang.sh
	bash tests/test-rc-commands.sh
	bash tests/test-json-output.sh
