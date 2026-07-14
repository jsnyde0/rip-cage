#!/usr/bin/env bash
# tests/golden-master/cases.sh — the golden-master case catalog for
# rip-cage-9oyh §1(a) (the container-free net). Each `case_<name>` function
# is invoked by capture.sh with a freshly-reset sandbox (lib/sandbox.sh);
# it must set GM_OUT/GM_ERR/GM_EXIT (usually via gm_capture) before
# returning. GM_CASES lists every case, in a stable order.
set -u

GM_CASES=(
  usage_no_args
  usage_unknown_verb
  schema
  completions_zsh
  completions_bash
  completions_missing_shell
  completions_unknown_shell
  flag_output_requires_json
  flag_dry_run_unsupported_verb
  flag_output_json_unsupported_verb_setup
  flag_output_json_unsupported_verb_attach
  version_flag
  build_bundled
  generate_dockerfile_bundled
  generate_dockerfile_from_source
  up_dry_run_json_running
  up_dry_run_json_exited_resume
  up_dry_run_json_created_resume
  up_dry_run_json_paused
  up_dry_run_json_restarting
  up_dry_run_json_removing
  up_dry_run_json_dead
  up_dry_run_json_absent_create
  up_dry_run_json_absent_create_image_absent
  up_dry_run_human_absent_create
  up_validate_warning_seam
  down_not_found
  destroy_dry_run_absent
  destroy_dry_run_running_json
  reload_dry_run_absent
  reload_dry_run_not_running
  ls_human_empty
  ls_json_empty
  config_show_yaml
  config_show_json
  config_get_raw
  config_init_no_ssh_detected
  doctor_host
  manifest_reconcile
  install_yes
  setup_zsh_first_run
  setup_bash_first_run
  setup_fish_unsupported
  setup_shell_unset
  attach_not_running
  exec_missing_separator
  exec_no_command_after_separator
  exec_extra_arg_before_separator
  exec_not_running_human
  exec_not_running_json
  allowlist_add_new
  allowlist_add_skip_existing
  allowlist_show_effective
  auth_refresh_human
  auth_refresh_json
)

# --- usage / unknown-verb / flags / version --------------------------------

case_usage_no_args() { gm_capture; }
case_usage_unknown_verb() { gm_capture bogus-verb; }

case_flag_output_requires_json() { gm_capture --output foo ls; }
case_flag_dry_run_unsupported_verb() { gm_capture --dry-run ls; }
case_flag_output_json_unsupported_verb_setup() { gm_capture --output json setup; }
case_flag_output_json_unsupported_verb_attach() { gm_capture --output json attach; }
case_version_flag() { gm_capture --version; }

# --- schema / completions ---------------------------------------------------

case_schema() { gm_capture schema; }
case_completions_zsh() { gm_capture completions zsh; }
case_completions_bash() { gm_capture completions bash; }
case_completions_missing_shell() { gm_capture completions; }
case_completions_unknown_shell() { gm_capture completions fish; }

# --- build / generate-dockerfile --------------------------------------------

case_build_bundled() {
  # Bundled default manifest (empty tools.yaml -> _manifest_default_yaml
  # floor). `docker build`/`docker run` are faked (see lib/fake-bin/docker);
  # the binary-root-owned assertion's `docker run --rm stat ...` calls fail
  # under the shim by construction (§3(i) contract: `docker run` -> exit 1),
  # so this case pins cmd_build's real, deterministic control flow up to and
  # including that post-build validator -- not a "successful build".
  gm_capture build
}

case_generate_dockerfile_bundled() {
  gm_capture generate-dockerfile
}

case_generate_dockerfile_from_source() {
  GM_MANIFEST_GLOBAL="${REPO_ROOT}/tests/fixtures/manifest-with-from-source-tool.yaml" \
    gm_capture generate-dockerfile
  unset GM_MANIFEST_GLOBAL
}

# --- up --dry-run --output json: all 8 container states --------------------
# Image present+current for every state (see cases.sh comment above --
# rc:4769's `warning`-omitting would_create+image-absent branch is the only
# state where image-absence changes the JSON *shape*; a dedicated case below
# covers that combination explicitly).

_gm_up_dry_run_state() {
  local state="$1" ws
  ws=$(gm_ws_realpath)
  GM_DOCKER_STATE="$state" \
  GM_DOCKER_LABEL_SOURCE_PATH="$ws" \
  GM_DOCKER_LABEL_EGRESS="on" \
  GM_DOCKER_LABEL_FWD_SSH="off" \
  GM_DOCKER_IMAGE_VERSION="$(gm_read_version)" \
    gm_capture --dry-run --output json up "$ws"
}

case_up_dry_run_json_running() { _gm_up_dry_run_state running; }
case_up_dry_run_json_exited_resume() { _gm_up_dry_run_state exited; }
case_up_dry_run_json_created_resume() { _gm_up_dry_run_state created; }
case_up_dry_run_json_paused() { _gm_up_dry_run_state paused; }
case_up_dry_run_json_restarting() { _gm_up_dry_run_state restarting; }
case_up_dry_run_json_removing() { _gm_up_dry_run_state removing; }
case_up_dry_run_json_dead() { _gm_up_dry_run_state dead; }
case_up_dry_run_json_absent_create() { _gm_up_dry_run_state absent; }

case_up_dry_run_json_absent_create_image_absent() {
  local ws
  ws=$(gm_ws_realpath)
  GM_DOCKER_STATE=absent GM_DOCKER_IMAGE_PRESENT=false \
    gm_capture --dry-run --output json up "$ws"
}

case_up_dry_run_human_absent_create() {
  local ws
  ws=$(gm_ws_realpath)
  GM_DOCKER_STATE=absent GM_DOCKER_IMAGE_VERSION="$(gm_read_version)" \
    gm_capture --dry-run up "$ws"
}

# --- §3(iii) RC_VALIDATE_WARNING seam (folds into the dry-run-json matrix
# per harness spec §3(iii): "Folds into §1(a)'s dry-run-json matrix (with
# the image-present precondition)"). RC_ALLOWED_ROOTS UNSET (not merely
# empty) so validate_path's non-interactive minimum-grant branch (rc:601)
# fires and sets RC_VALIDATE_WARNING; a running container (would_attach)
# reaches the `_up_json_output` branch that reads it back into the JSON
# `warning` field (rc:4769) unconditionally of image state, per the actual
# guard structure (`would_create && image_absent` is the ONLY case that
# skips it) -- so this case exercises the seam without needing the
# image-present precondition (image state is left at the shim default).
case_up_validate_warning_seam() {
  local ws
  ws=$(gm_ws_realpath)
  GM_NO_ALLOWED_ROOTS=1 \
  GM_DOCKER_STATE=running \
  GM_DOCKER_LABEL_SOURCE_PATH="$ws" \
  GM_DOCKER_LABEL_EGRESS="on" \
  GM_DOCKER_LABEL_FWD_SSH="off" \
  GM_DOCKER_IMAGE_VERSION="$(gm_read_version)" \
    gm_capture --dry-run --output json up "$ws"
}

# --- down / destroy / reload --dry-run --------------------------------------

case_down_not_found() {
  GM_DOCKER_STATE=absent gm_capture down some-cage
}

case_destroy_dry_run_absent() {
  GM_DOCKER_STATE=absent gm_capture --dry-run --output json destroy some-cage
}

case_destroy_dry_run_running_json() {
  GM_DOCKER_STATE=running GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" \
    gm_capture --dry-run --output json destroy some-cage
}

case_reload_dry_run_absent() {
  GM_DOCKER_STATE=absent gm_capture --dry-run reload some-cage
}

case_reload_dry_run_not_running() {
  GM_DOCKER_STATE=exited GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" \
    gm_capture --dry-run reload some-cage
}

# --- ls ----------------------------------------------------------------

case_ls_human_empty() { gm_capture ls; }
case_ls_json_empty() { gm_capture --output json ls; }

# --- config show/get/init ----------------------------------------------

case_config_show_yaml() { gm_capture config show "$GM_WS"; }
case_config_show_json() { gm_capture config show "$GM_WS" --json; }
case_config_get_raw() { gm_capture config get mounts.denylist "$GM_WS"; }

case_config_init_no_ssh_detected() {
  # No .ssh dir / no git remotes in the fixture workspace -> the
  # deterministic "nothing to lock down" early-exit branch.
  gm_capture_in "$GM_WS" config init
}

# --- doctor --host -------------------------------------------------------

case_doctor_host() { gm_capture doctor --host; }

# --- manifest reconcile (§4 gap-fill folds into §1(a); see also the
# dedicated tests/test-manifest-reconcile-verb.sh for the backup-before-
# overwrite assertion in isolation) --------------------------------------

case_manifest_reconcile() {
  cat > "${GM_XDG}/rip-cage/tools.yaml" <<'YAML'
version: 1
tools:
  - name: my-custom-tool
    archetype: TOOL
    version_pin: "1.0.0"
    egress: []
    mounts: []
    install_cmd: "true"
YAML
  gm_capture manifest reconcile
}

# --- install --yes -------------------------------------------------------

case_install_yes() {
  rm -f "${GM_XDG}/rip-cage/config.yaml"
  gm_capture install --yes
}

# --- setup (zsh/bash/fish/unset) ------------------------------------------

case_setup_zsh_first_run() {
  GM_SHELL_OVERRIDE="/bin/zsh" gm_capture setup
}

case_setup_bash_first_run() {
  GM_SHELL_OVERRIDE="/bin/bash" gm_capture setup
}

case_setup_fish_unsupported() {
  GM_SHELL_OVERRIDE="/usr/bin/fish" gm_capture setup
}

case_setup_shell_unset() {
  # An explicit EMPTY assignment (not an unset env var) -- see
  # lib/sandbox.sh's gm_capture: some environments re-populate an unset
  # SHELL via bash's own startup path resolution, which would make this
  # case flaky across hosts. An empty SHELL="" reaches the identical
  # `"${SHELL:-}"` empty-string branch deterministically everywhere.
  GM_SHELL_OVERRIDE="" gm_capture setup
}

# --- attach / exec error-path matrix (§4 gap-fill folds into §1(a); see
# also tests/test-attach-exec-errors.sh for the fuller matrix) ------------

case_attach_not_running() {
  GM_DOCKER_STATE=absent gm_capture attach some-cage
}

case_exec_missing_separator() {
  gm_capture exec some-cage echo hi
}

case_exec_no_command_after_separator() {
  gm_capture exec some-cage --
}

case_exec_extra_arg_before_separator() {
  gm_capture exec some-cage extra-arg --
}

case_exec_not_running_human() {
  GM_DOCKER_STATE=absent gm_capture exec some-cage -- echo hi
}

case_exec_not_running_json() {
  GM_DOCKER_STATE=absent gm_capture --output json exec some-cage -- echo hi
}

# --- allowlist show/add --------------------------------------------------

case_allowlist_add_new() {
  gm_capture allowlist add example.com "--config-file=${GM_WS}/.rip-cage.yaml"
}

case_allowlist_add_skip_existing() {
  mkdir -p "$GM_WS"
  printf 'version: 2\nnetwork:\n  allowed_hosts:\n    - example.com\n' > "${GM_WS}/.rip-cage.yaml"
  gm_capture --output json allowlist add example.com "--config-file=${GM_WS}/.rip-cage.yaml"
}

case_allowlist_show_effective() {
  mkdir -p "$GM_WS"
  printf 'version: 2\nnetwork:\n  allowed_hosts:\n    - example.com\n' > "${GM_WS}/.rip-cage.yaml"
  gm_capture allowlist show --effective "--config-file=${GM_WS}/.rip-cage.yaml"
}

# --- auth refresh (non-macOS path; lib/fake-bin/uname always reports
# Linux -- see rip-cage-5fsy in .claude/harness.md) ------------------------

case_auth_refresh_human() { gm_capture auth refresh; }
case_auth_refresh_json() { gm_capture --output json auth refresh; }
