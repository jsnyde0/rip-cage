.DEFAULT_GOAL := help

PREFIX ?= $(HOME)/.local

BASH_SCRIPTS := rc cli/*.sh cli/lib/*.sh cage/init/init-rip-cage.sh cage/floor/floor-probe.sh cage/substrate/bd-wrapper.sh tests/test-floor-probe.sh tests/test-prerequisites.sh tests/test-bash32-constructs.sh tests/test-docker-daemon-hang.sh tests/test-security-model-injection.sh tests/_scratch-cage-lib.sh tests/test-host-scratch-root.sh tests/test-cage-host-bridge-probe.sh tests/test-scratch-cage-cleanup.sh tests/test-scratch-cage-registry.sh tests/test-image-drift-resume.sh tests/run-host.sh tests/test-run-host-driver.sh tests/_host-sandbox-lib.sh tests/run-one.sh tests/test-build-msb-load.sh tests/test-msb-boot-smoke.sh tests/test-claude-home-dir-seed.sh tests/test-msb-claude-home-resume.sh tests/test-msb-flags-generator.sh tests/test-msb-flags-effect-probes.sh tests/test-msb-mount-denylist-live.sh tests/test-msb-flags-dind-volume.sh tests/test-dind-compose-disk-kind-live.sh tests/test-msb-engine-deletion-effect-probes.sh tests/test-msb-ssh-retirement-effect-probes.sh tests/test-msb-runtime.sh tests/test-up-msb-egress-config.sh tests/test-up-msb-args-translate.sh tests/test-msb-lifecycle-create-resume.sh tests/test-msb-mount-shape-resume-guard-live.sh tests/test-msb-lifecycle-graceful-stop.sh tests/test-msb-deny-visibility.sh tests/test-msb-lifecycle-doctor.sh tests/test-msb-lifecycle-reload-repair-loop.sh tests/test-msb-lifecycle-cockpit-reregistration.sh tests/test-msb-attach-exec-live.sh tests/test-msb-down-destroy-live.sh tests/test-msb-ls-build-live-probes.sh tests/test-msb-test-live-probe.sh tests/test-msb-repair-loop-resume-roundtrip.sh tests/test-msb-factory-socket-api-drive.sh

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

lint: ## Run the bash-3.2 compat gate, then shellcheck (pinned docker image — matches CI)
	bash tests/test-bash32-constructs.sh
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:v0.11.0 -x $(BASH_SCRIPTS)

test: ## Run host-only test scripts (no container required)
	bash tests/test-prerequisites.sh
	bash tests/test-docker-daemon-hang.sh
	bash tests/test-rc-commands.sh
	bash tests/test-json-output.sh
