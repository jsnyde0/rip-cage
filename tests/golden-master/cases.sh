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
  flag_output_requires_json
  flag_dry_run_unsupported_verb
  version_flag
  build_bundled
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
  destroy_dry_run_absent
  destroy_dry_run_running_json
  doctor_host
  auth_refresh_human
  auth_refresh_json
)

# --- usage / unknown-verb / flags / version --------------------------------

case_usage_no_args() { gm_capture; }
case_usage_unknown_verb() { gm_capture bogus-verb; }

case_flag_output_requires_json() { gm_capture --output foo ls; }
case_flag_dry_run_unsupported_verb() { gm_capture --dry-run ls; }
case_version_flag() { gm_capture --version; }

# --- retired verbs ------------------------------------------------------------
# `rc schema` retired with the rip-cage config schema (rip-cage-ely4.9 /
# ADR-031 D2 / ADR-003-agent-friendly-cli.md D5) -- the `case_schema` golden-
# master case that lived here is gone with it.
#
# `rc completions` retired with the six-verb thinning (rip-cage-ely4.10 /
# ADR-031 D3) -- case_completions_zsh / _bash / _missing_shell / _unknown_shell
# are gone with it, as are case_flag_output_json_unsupported_verb_setup and
# _attach: the verbs those two named now reach plain usage, which
# case_usage_unknown_verb already pins.


# --- build ------------------------------------------------------------------

case_build_bundled() {
  # No tool list anywhere: the manifest retired (ADR-031 D4) (was: empty tools.yaml
  # floor). `docker build`/`docker run` are faked (see lib/fake-bin/docker);
  # the binary-root-owned assertion's `docker run --rm stat ...` calls fail
  # under the shim by construction (§3(i) contract: `docker run` -> exit 1),
  # so this case pins cmd_build's real, deterministic control flow up to and
  # including that post-build validator -- not a "successful build".
  gm_capture build
}


# --- up --dry-run --output json: all 8 container states --------------------
# Image present+current for every state (see cases.sh comment above --
# cli/up.sh:_up_json_output's `warning`-omitting would_create+image-absent branch is the only
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
# empty) so validate_path's non-interactive minimum-grant branch (cli/lib/path.sh:validate_path)
# fires and sets RC_VALIDATE_WARNING; a running container (would_attach)
# reaches the `_up_json_output` branch that reads it back into the JSON
# `warning` field (cli/up.sh:_up_json_output) unconditionally of image state, per the actual
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

# --- destroy --dry-run ------------------------------------------------------
# `rc down` and `rc reload` retired with the six-verb thinning
# (rip-cage-ely4.10 / ADR-031 D3): stopping a cage is `msb stop`, and the
# cold-recreate folded into `rc up --replace`. case_down_not_found,
# case_reload_dry_run_absent and case_reload_dry_run_not_running are gone.


case_destroy_dry_run_absent() {
  GM_DOCKER_STATE=absent gm_capture --dry-run --output json destroy some-cage
}

case_destroy_dry_run_running_json() {
  GM_DOCKER_STATE=running GM_DOCKER_LABEL_SOURCE_PATH="$(gm_ws_realpath)" \
    gm_capture --dry-run --output json destroy some-cage
}


# --- retired fleet/config verbs ------------------------------------------
# `rc ls` retired with the six-verb thinning (rip-cage-ely4.10 / ADR-031 D3) --
# listing cages is `msb list`. case_ls_human_empty, case_ls_json_empty and
# case_ls_human_populated (which pinned the human column layout
# NAME/STATUS/UPTIME/EGRESS/MODE/SOURCE PATH) are gone with it.

# `rc config show`/`rc config get`/`rc config init` retired with the rip-cage
# config schema (rip-cage-ely4.9 / ADR-031 D2) -- the case_config_show_yaml /
# case_config_show_json / case_config_get_raw / case_config_init_no_ssh_detected
# golden-master cases that lived here are gone with them.

# --- doctor --host -------------------------------------------------------

case_doctor_host() { gm_capture doctor --host; }

# `rc manifest reconcile` retired with the six-verb thinning (rip-cage-ely4.10
# / ADR-031 D3) -- its successor is editing the file. case_manifest_reconcile
# is gone with it, and so is case_generate_dockerfile_bundled /
# _from_source, whose verb retires with the manifest it composed.

# `rc install` retired with the rip-cage config schema (rip-cage-ely4.9 /
# ADR-031 D2) -- the case_install_yes golden-master case that lived here is
# gone with it.

# `rc setup` retired with the six-verb thinning (rip-cage-ely4.10 / ADR-031
# D3) -- case_setup_zsh_first_run / _bash_first_run / _fish_unsupported /
# _shell_unset are gone with it.


# `rc attach` and `rc exec` retired with the six-verb thinning
# (rip-cage-ely4.10 / ADR-031 D3) -- a shell in a cage is `msb exec <cage> --
# zsh`. case_attach_not_running and the whole case_exec_* error-path matrix
# are gone with them.


# `rc allowlist` retired with the rip-cage config schema (rip-cage-ely4.9 /
# ADR-031 D2 -- adding an egress host is now a line in the project's native
# msb --conf file, then `rc up --replace`) -- the case_allowlist_add_new /
# case_allowlist_add_skip_existing / case_allowlist_show_effective
# golden-master cases that lived here are gone with it.

# --- auth refresh (non-macOS path; lib/fake-bin/uname always reports
# Linux -- see rip-cage-5fsy in .claude/verification.md) ------------------------

case_auth_refresh_human() { gm_capture auth refresh; }
case_auth_refresh_json() { gm_capture --output json auth refresh; }
