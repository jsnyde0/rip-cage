.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local

BASH_SCRIPTS := rc init-rip-cage.sh hooks/block-compound-commands.sh test-safety-stack.sh test-prerequisites.sh

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

test: ## Run shellcheck on bash scripts
	shellcheck $(BASH_SCRIPTS)

lint: test ## Alias for test (shellcheck)
