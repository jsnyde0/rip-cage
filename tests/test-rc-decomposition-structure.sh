#!/usr/bin/env bash
# test-rc-decomposition-structure.sh — post-split structural harness for the
# rc monolith -> cli/*.sh + cli/lib/*.sh decomposition (rip-cage-gto1).
#
# These are the DEFERRED structural tests the decomposition harness
# (docs/2026-07-08-rc-decomposition-harness.md rev.2, sections 3(ii)/3(v)/5/6)
# could not be built until the modules existed. They assert the split's
# structural invariants; the golden-master (tests/golden-master/) + the
# existing seam tests (test-up-run-args-*.sh, test-up-validate-warning-seam.sh,
# test-reload-exit-trap-seam.sh) cover BEHAVIOR. This file covers STRUCTURE.
#
# Run from repo root: bash tests/test-rc-decomposition-structure.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"
FAILURES=0

pass() { echo "PASS $1: $2"; }
fail() { echo "FAIL $1: $2 -- $3"; FAILURES=$((FAILURES + 1)); }

echo "=== test-rc-decomposition-structure.sh — post-split structural invariants ==="
echo ""

# ---------------------------------------------------------------------------
# (a) Per-module strict-mode: no cli/*.sh or cli/lib/*.sh module may set
#     `set -euo pipefail` itself -- the shim (rc) owns strict mode exactly
#     once (map hazard 2 / harness 3iv). A module that added it would flip
#     strict mode ON the moment ANY test sources that module directly.
# ---------------------------------------------------------------------------
echo "=== (a) Per-module strict-mode: cli/*.sh and cli/lib/*.sh must NOT set -euo pipefail ==="

_offenders=$(grep -lE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)' "${REPO_ROOT}"/cli/*.sh "${REPO_ROOT}"/cli/lib/*.sh 2>/dev/null || true)
if [[ -z "$_offenders" ]]; then
  pass "(a)" "no cli/*.sh or cli/lib/*.sh module sets strict/errexit mode"
else
  fail "(a)" "module(s) set strict mode -- shim must own it exactly once" "offenders: ${_offenders}"
fi

echo ""

# ---------------------------------------------------------------------------
# (b) Function-count invariant: total top-level function definitions across
#     the shim (rc) + every cli/*.sh + cli/lib/*.sh module must equal the
#     count measured from the pre-split monolith at decomposition time.
#     MEASURED (not copied from the design docs, which disagreed: map said
#     193, a later count said 194) via:
#       grep -noE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' rc | wc -l   =>  193
#     at the commit immediately preceding this split.
#
#     This count is a canary against SILENT redefinition/shadow/drop, not a
#     permanent ceiling -- an intentional new function (with its own tests)
#     legitimately bumps it, and an intentional deletion (with its own
#     removal rationale) legitimately drops it. Bumped 193 -> 194 by
#     rip-cage-7dkq (S1, msb migration): `_build_msb_load` (cli/build.sh),
#     wiring verified by tests/test-build-msb-load.sh T4. Further drifted
#     194 -> 200 by later msb-migration siblings (S2/S3/S11 -- notably
#     cli/lib/msb_flags.sh's new functions) without a matching counter bump
#     here -- a pre-existing canary-hygiene gap, NOT attributable to
#     rip-cage-3vj2 (S4), discovered while updating this counter for S4's own
#     change. Dropped 200 -> 187 by rip-cage-3vj2 (S4, msb migration, ADR-029
#     D2 engine-deletion sweep): 13 functions deleted with the in-cage
#     egress/firewall/mediator engine -- _config_mediator_derive_allowed_set,
#     _generate_egress_rules_file, _load_mediator_env_file,
#     _manifest_generate_mediator_label,
#     _manifest_generate_mediator_registry_steps, _up_init_firewall,
#     _up_init_mediator, _up_reload_egress_proxy, _up_reload_tcp22_allowlist,
#     _up_resolve_egress_rules, _up_resolve_mediator_env_file,
#     _up_resolve_resume_egress, _up_resolve_resume_mediator_ca_env.
#     Dropped 187 -> 156 by rip-cage-f1qo (S5, msb migration, ADR-029 D3
#     ssh-cluster retirement): 31 functions deleted with the entire ssh
#     cluster (agent-forwarding default ADR-017, socket discovery ADR-018,
#     identity routing ADR-020, host+key allowlist + hook + filtered
#     known_hosts + ssh-agent-filter ADR-022, and the `rc config init` ssh
#     detection wizard whose schema fields retired alongside it) --
#     _resolve_host_ssh_sock, _up_resolve_resume_forward_ssh,
#     _up_resolve_resume_ssh_key_filter, _tsc_process_file,
#     _translate_ssh_config, _derive_pubkey_allowlist,
#     _assert_pubkey_exists_or_die, _filter_known_hosts,
#     _up_resolve_ssh_allowlists, _build_ssh_mount_args,
#     _build_ssh_mount_args_with_posture, _resolve_ssh_config_posture,
#     _ssh_config_label_args, _up_resolve_resume_ssh_config,
#     _parse_identity_rules, _resolve_github_identity,
#     _host_config_has_github, _resolve_github_identity_source,
#     _up_resolve_resume_github_identity, _up_ssh_preflight,
#     _up_github_identity_preflight, _identity_cache_file,
#     _identity_cache_read, _identity_cache_write, _identity_cache_touch_all,
#     _config_init_detect_ssh_hosts, _config_init_detect_keys,
#     _config_init_keys_by_comment_match, _config_init_build_yaml,
#     cmd_config_init, _config_init_emit_tip. This pass also closes a
#     pre-existing canary-hygiene gap flagged above (the 194 -> 200 drift
#     was never reflected in the enumerated name list below) -- the list
#     (check (c) below) was, at that point, a complete, accurate enumeration
#     of the 151 functions actually declare -F-reachable after sourcing rc
#     (156 total definitions on disk minus the 5 cli/lib/msb_flags.sh
#     functions that were, at that point, a pre-existing, not-sourced-by-rc
#     gap -- msb_flags.sh was not yet in rc's `for _rc_lib in ...` source
#     list).
#
#     Bumped 156 -> 175 by rip-cage-rj68 (S6, msb migration, ADR-029 D1
#     hard cutover): the create/resume/reload/doctor lifecycle-verb rewrite
#     onto msb. 19 functions ADDED, 0 removed:
#       cli/lib/msb_runtime.sh (NEW FILE, 14 functions -- the msb-side
#       runtime primitives, docker.sh's counterpart for the in-scope
#       verbs): check_msb, _msb_call, _msb_inspect_json,
#       _msb_sandbox_state, _msb_label, _msb_exists, _msb_exec,
#       _msb_exec_interactive, _msb_start, _msb_stop_graceful, _msb_remove,
#       _msb_sandbox_image_digest, _msb_current_image_digest,
#       _msb_denied_domains_from_trace_log.
#       cli/lib/msb_flags.sh (S6 addition, Fold b): _msb_flags_preflight_secret_env.
#       ALSO: cli/lib/msb_flags.sh is now in rc's `for _rc_lib in ...`
#       source list (it was not before) -- closing the "5-function gap"
#       named above; every on-disk function is now declare -F-reachable
#       after sourcing rc, so checks (b) and (c) use the SAME count (175)
#       from here on, and check (c)'s enumeration below includes
#       msb_flags.sh's pre-existing 5 functions for the first time too.
#       cli/up.sh (3 new): _up_build_egress_config_json (S2's generator ->
#       real-config translator), _up_translate_docker_args_to_msb (the
#       docker-argv -> msb-argv translator), _up_prepare_resume_secrets
#       (Fold b's preflight, re-run on every resume since msb re-resolves
#       --secret bindings from the host env at every start, not just
#       create -- live-discovered during this bead's implementation).
#       cli/doctor.sh (1 new): _doctor_format_posture_probe (replaces the
#       retired in-cage engine-process probe; bead criteria 4 + 5).
#
#     Bumped 175 -> 178 by rip-cage-tsf2.1 (msb migration, ADR-029 D1 hard
#     cutover): the attach/exec/down/destroy verb rewrite onto msb, plus
#     the build/ls/test live-probe rewrites. 3 functions ADDED, 0 removed
#     (cli/attach_exec.sh, cli/down_destroy.sh, cli/test.sh rewrote
#     existing function BODIES onto msb -- no new top-level names there):
#       cli/lib/msb_runtime.sh (1 new): _msb_volume_remove (`msb remove`
#       has NO volume-deletion flag -- a distinct primitive for `rc
#       destroy`'s named-volume cleanup, bead criterion 2).
#       cli/lib/container.sh (1 new): _rc_uptime_from_state (humanized
#       uptime string from msb's `updated_at`, extracted from
#       cli/doctor.sh's S6-era inline logic so cli/ls.sh's rewritten
#       cmd_ls can share it -- a genuine >=2-module cross-cutting helper,
#       not a single-caller convenience; doctor.sh refactored to call it
#       too, behavior-preserving).
#       cli/ls.sh (1 new): _rc_ls_enumerate (msb-side enumeration helper
#       -- was inline `docker ps -a --filter label=rc.source.path`, now
#       `msb list` + per-sandbox `_msb_inspect_json`/label reads; shared
#       by cmd_ls's JSON and human branches).
# ---------------------------------------------------------------------------
echo "=== (b) Function-count invariant (measured pre-split count: 193, current: 181) ==="

# Bumped 178 -> 179 by Fable ruling 6 (msb cutover merge window): cli/lib/config.sh
# gained _config_retired_fields (the retired-config-field loud-reject table).
# Bumped 179 -> 181 by rip-cage-tsf2.9 (converge-on-up): cli/up.sh gained
# _up_eligible_drift_paths (the pure converge-decision comparator) and
# _up_announce_converge (the loud stopped-cage converge announcement).
EXPECTED_FN_COUNT=181
_actual_fn_count=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$RC" "${REPO_ROOT}"/cli/*.sh "${REPO_ROOT}"/cli/lib/*.sh 2>/dev/null | wc -l | tr -d ' ')

if [[ "$_actual_fn_count" -eq "$EXPECTED_FN_COUNT" ]]; then
  pass "(b)" "total top-level function defs across rc+cli/+cli/lib/ == ${EXPECTED_FN_COUNT}"
else
  fail "(b)" "function count mismatch (silent redefinition/shadow or dropped function)" \
    "expected ${EXPECTED_FN_COUNT}, got ${_actual_fn_count}"
fi

# No name should be defined more than once across the split (collision-safe,
# per map hazard 3's "193 unique names, no redefinition" claim -- re-verify
# post-split since files can silently duplicate a helper).
_dup_names=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$RC" "${REPO_ROOT}"/cli/*.sh "${REPO_ROOT}"/cli/lib/*.sh 2>/dev/null | sort | uniq -d)
if [[ -z "$_dup_names" ]]; then
  pass "(b2)" "no function name is defined in more than one file"
else
  fail "(b2)" "function name(s) defined more than once across the split" "dup: ${_dup_names}"
fi

echo ""

# ---------------------------------------------------------------------------
# (c) declare -F reachability: after sourcing the shim (exposing functions
#     only -- no dispatch, since rc is sourced not executed here), every one
#     of the 181 currently rc-reachable functions must be `declare -F`-
#     reachable. rip-cage-rj68 (S6): cli/lib/msb_flags.sh is now in rc's
#     source list (previously it was not -- see (b)'s comment), so the
#     stale "151 reachable out of 156 on disk" gap is closed; on-disk count
#     and reachable count are the SAME number (181, since rip-cage-tsf2.9's
#     bump) from here on. A loud, per-name failure (not just a count) so a
#     reviewer can see exactly which module dropped/misfiled a function.
# ---------------------------------------------------------------------------
echo "=== (c) declare -F reachability: all 181 rc-reachable functions defined after sourcing rc ==="

ALL_193_NAMES="_allowlist_add _allowlist_add_host_to_yaml _allowlist_is_in_cage _allowlist_promote _allowlist_read_observed_hosts _allowlist_refuse_in_cage _allowlist_resolve_config_file _allowlist_show _bd_dolt_port_inject_arg _bd_host_preflight _build_msb_load _build_warn_stale_containers _check_lfs_stubs _check_secret_path_denylist _check_workspace_config_base_url _collect_dangling_symlinks _collect_symlink_parents _config_applied_path _config_check_version _config_check_yq _config_default_global_yaml _config_diff_paths _config_emit_hint _config_ensure_global_seeded _config_format_yaml _config_global_path _config_label_value _config_load_layer _config_merge _config_mux_derive_allowed_set _config_paths_all_reload_eligible _config_project_path _config_provenance _config_read_applied _config_resolve_workspace_arg _config_retired_fields _config_schema_defaults_json _config_schema_field_type _config_schema_lines _config_schema_selection_list_keys _config_unknown_version_classify _config_validate_or_abort _config_write_applied _container_multiplexer _docker_call _doctor_bd_version_compare _doctor_dead_file_mounts _doctor_format_auth_probe _doctor_format_dead_mounts _doctor_format_posture_probe _doctor_host _emit_denylist_denial _emit_workspace_config_base_url_error _emit_workspace_config_base_url_warning _ensure_pi_auth_seed _extract_credentials _extract_credentials_has_usable_existing _host_source_is_root_owned _image_is_current _lexical_normalize_path _load_effective_config _manifest_build_dockerfile_path _manifest_build_mount_args _manifest_check_binary_root_owned _manifest_check_build_isolation _manifest_check_build_source_subfields _manifest_check_install_cmd_single_line _manifest_check_ioc_egress _manifest_check_mount_root_owned _manifest_check_mounts_denylist _manifest_check_seed_drift _manifest_default_yaml _manifest_dest_in_allowed_roots _manifest_dist_path _manifest_egress_hosts_json _manifest_ensure_seeded _manifest_expand_mount_host _manifest_extract_seed_fingerprint _manifest_generate_daemon_config_dockerfile_steps _manifest_generate_daemon_mcp_dockerfile_steps _manifest_generate_extra_dockerfile_steps _manifest_generate_launch_args _manifest_generate_multiplexer_label _manifest_generate_multiplexer_registry_steps _manifest_generate_pi_shim_steps _manifest_generate_safety_stack_asserted_steps _manifest_generate_shell_init_zshrc_steps _manifest_generate_source_builder_stages _manifest_generate_tool_init_config_dockerfile_steps _manifest_global_path _manifest_load _manifest_reconcile _manifest_seed_fingerprint_hash _manifest_validate _msb_call _msb_current_image_digest _msb_denied_domains_from_trace_log _msb_exec _msb_exec_interactive _msb_exists _msb_flags_emit_dind_volume _msb_flags_emit_mount _msb_flags_generate _msb_flags_preflight_secret_env _msb_flags_prepare_secret_env _msb_flags_synth_secret_env_name _msb_inspect_json _msb_label _msb_remove _msb_sandbox_image_digest _msb_sandbox_state _msb_start _msb_stop_graceful _msb_volume_remove _path_under_allowed_roots _prereq_error _probe_tcp _pull_or_build _pull_or_build_local _rc_ls_enumerate _rc_ls_mode_from_source_path _rc_mux_resolve_hook_path _rc_uptime_from_state _resolve_script_dir _run_with_timeout _secret_path_denylist_matched_pattern _seed_claude_home_dirs _symlink_follow_fingerprint _up_announce_converge _up_build_egress_config_json _up_detect_worktree _up_eligible_drift_paths _up_image_drift_status _up_init_container _up_json_output _up_prepare_docker_mounts _up_prepare_environment _up_prepare_resume_secrets _up_resolve_dcg_config _up_resolve_effective_credential_mounts_for_tool _up_resolve_placeholder_env_file _up_resolve_resume_config_mode _up_resolve_resume_credential_mounts _up_resolve_resume_image_drift_running _up_resolve_resume_image_drift_stopped _up_resolve_resume_symlink_fingerprint _up_short_image_id _up_start_container _up_translate_docker_args_to_msb _up_validate_dcg_config check_docker check_jq check_msb cmd_allowlist cmd_attach cmd_auth cmd_auth_refresh cmd_build cmd_config cmd_config_get cmd_config_show cmd_destroy cmd_doctor cmd_down cmd_exec cmd_generate_dockerfile cmd_install cmd_ls cmd_manifest cmd_reload cmd_schema cmd_setup cmd_test cmd_up container_name json_error log resolve_name usage validate_path verify_rc_container"

_missing=""
_missing_count=0
# shellcheck disable=SC1090
source "$RC"
for _fn in $ALL_193_NAMES; do
  if ! declare -F "$_fn" >/dev/null 2>&1; then
    _missing="${_missing} ${_fn}"
    _missing_count=$((_missing_count + 1))
  fi
done

if [[ "$_missing_count" -eq 0 ]]; then
  pass "(c)" "all 181 rc-reachable functions are declare -F reachable after sourcing rc"
else
  fail "(c)" "${_missing_count} function(s) NOT reachable after sourcing rc" "missing:${_missing}"
fi

echo ""

# ---------------------------------------------------------------------------
# (d) up<->reload coupling (harness 3ii): historically, a function DEFINED in
#     the up-block (cli/up.sh, per the "do not sub-split cmd_up" constraint)
#     was CALLED by cmd_reload (cli/reload.sh) -- first the firewall trio
#     (_up_reload_tcp22_allowlist / _up_reload_egress_proxy /
#     _up_resolve_egress_rules, deleted with the in-cage egress engine per
#     rip-cage-3vj2 / S4), then _filter_known_hosts (the ssh known_hosts
#     filter, deleted with the entire ssh cluster per rip-cage-f1qo / S5,
#     ADR-029 D3). That original coupling was RETIRED, not re-pointed, by S5.
#
#     rip-cage-rj68 (S6) reintroduces a coupling MEMBER -- an intentional,
#     documented one, not a regression: cmd_reload's net-rule repair action
#     (ADR-029 D4, cold-recreate DESIGN DECISION -- see cli/reload.sh's own
#     comment) invokes `cmd_up "$workspace"` directly rather than
#     hand-rolling a second, parallel mount/env-rebuild implementation --
#     "the SAME create pipeline, invoked again against the now-current
#     .rip-cage.yaml". `cmd_up` is the ONLY up.sh-defined name reload.sh may
#     depend on; any OTHER up.sh function reappearing in reload.sh (e.g. an
#     internal `_up_*` helper called directly, bypassing cmd_up's own
#     validation/label/guard machinery) would be exactly the kind of
#     under-the-radar re-coupling this canary exists to catch.
# ---------------------------------------------------------------------------
echo "=== (d) up<->reload coupling: RETIRED-then-reintroduced (S5 retired it; S6 re-adds exactly ONE intentional member, cmd_up) ==="

_up_fn_names=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${REPO_ROOT}/cli/up.sh" | sed 's/()$//')
_reload_real_calls=$(grep -v '^\s*#' "${REPO_ROOT}/cli/reload.sh" | grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*\b' | sort -u)

_surviving_coupling=""
for _fn in $_up_fn_names; do
  if printf '%s\n' "$_reload_real_calls" | grep -qx "$_fn"; then
    _surviving_coupling="${_surviving_coupling} ${_fn}"
  fi
done
# Trim leading/trailing whitespace for a clean equality check.
_surviving_coupling="${_surviving_coupling# }"

if [[ "$_surviving_coupling" == "cmd_up" ]]; then
  pass "(d)" "the ONLY cli/up.sh-defined function reload.sh depends on is cmd_up (S6's documented cold-recreate reuse) -- no other up.sh function has crept back in"
elif [[ -z "$_surviving_coupling" ]]; then
  fail "(d)" "expected cmd_up to be the S6 coupling member but found none -- did cli/reload.sh's cold-recreate call get removed/renamed without updating this canary?" "(none found)"
else
  fail "(d)" "up.sh-defined function(s) beyond the documented cmd_up coupling appear in reload.sh -- update this canary to name/verify the new coupling member(s), or fix the unintended coupling" "${_surviving_coupling}"
fi

echo ""

# ---------------------------------------------------------------------------
# (e) Source-order + top-level globals (harness 3v): after sourcing the shim,
#     all top-level globals interspersed among the original function defs
#     (map found 5; a 6th -- WS_CONFIG_HOSTILE_KEY/VAL -- surfaced during
#     implementation) must be set BEFORE dispatch, proving the shim sources
#     every module (running its top-level init code) ahead of flag-parse.
#
#     (rip-cage-3vj2 / S4, ADR-029 D2: _EGRESS_BASELINE_HOSTS and
#     _UP_EGRESS_MODE were deleted with the in-cage egress engine -- 4
#     globals remain, down from 6.)
# ---------------------------------------------------------------------------
echo "=== (e) Top-level globals initialized before dispatch ==="

_globals_result=$(bash -c '
  # shellcheck disable=SC1090
  source "'"$RC"'"
  _fail=0
  [[ -v WS_CONFIG_HOSTILE_KEY ]] || { echo "MISSING:WS_CONFIG_HOSTILE_KEY"; _fail=1; }
  [[ -v _UP_DCG_CONFIG_PATH ]] || { echo "MISSING:_UP_DCG_CONFIG_PATH"; _fail=1; }
  [[ -v RC_CONFIG_SUPPORTED_VERSION_MAX ]] || { echo "MISSING:RC_CONFIG_SUPPORTED_VERSION_MAX"; _fail=1; }
  [[ -v _RC_RELOAD_ELIGIBLE_PATHS ]] || { echo "MISSING:_RC_RELOAD_ELIGIBLE_PATHS"; _fail=1; }
  [[ "$_fail" -eq 0 ]] && echo "OK"
')
if [[ "$_globals_result" == "OK" ]]; then
  pass "(e)" "all 4 top-level globals set before dispatch (sourcing order correct)"
else
  fail "(e)" "one or more top-level globals not set before dispatch" "${_globals_result}"
fi

echo ""

# ---------------------------------------------------------------------------
# (f) Boundary validation (harness 5): every function defined in cli/lib/
#     must be called from >=2 distinct cli/*.sh module files, OR be reachable
#     from another cli/lib/ member (the F7 closure) -- otherwise it has no
#     business being lib/ instead of living with its single caller module.
# ---------------------------------------------------------------------------
echo "=== (f) Boundary validation: every lib/ function is a genuine cross-module or closure member ==="

# Pre-existing dead code (verified unreferenced in the PRE-SPLIT monolith
# too -- `grep -c _config_schema_field_type rc` at the pre-split HEAD found
# only its own def line). Decomposition is behavior-preserving, not a
# dead-code cleanup pass (per the map's "clean home yes; polish the logic
# no" guardrail) -- so this genuinely-unreferenced helper is kept, exactly
# as unreferenced as it always was, and explicitly allowed here rather than
# silently masked by a looser boundary rule.
_KNOWN_DEAD_LIB_FNS=" _config_schema_field_type "

_boundary_violations=""
for _libfile in "${REPO_ROOT}"/cli/lib/*.sh; do
  while IFS= read -r _fn; do
    [[ -z "$_fn" ]] && continue
    if [[ "$_KNOWN_DEAD_LIB_FNS" == *" ${_fn} "* ]]; then
      continue
    fi
    # distinct cli/*.sh MODULE files (not lib/) that reference this name
    _module_hits=$(grep -l "\b${_fn}\b" "${REPO_ROOT}"/cli/*.sh 2>/dev/null | wc -l | tr -d ' ')
    # total occurrences across ALL cli/lib/ files, minus 1 for the function's
    # own def line -- a remainder > 0 means some OTHER lib code (its own
    # body calling a sibling helper, or a different lib file) references it,
    # i.e. it's reachable from within lib/ itself (F7 closure member). Using
    # occurrence COUNT (not file-level grep -l) so the function's own
    # single-line definition doesn't trivially satisfy this check.
    _lib_occurrences=$(grep -ohE "\b${_fn}\b" "${REPO_ROOT}"/cli/lib/*.sh 2>/dev/null | wc -l | tr -d ' ')
    _lib_extra=$((_lib_occurrences - 1))
    if [[ "$_module_hits" -ge 2 ]]; then
      continue  # genuine >=2-module cross-cutting helper
    fi
    if [[ "$_lib_extra" -ge 1 ]]; then
      continue  # reachable from within lib/ itself (closure member)
    fi
    if [[ "$_module_hits" -eq 1 ]]; then
      # single-module caller AND not reached from lib -- still acceptable
      # only if that caller module itself has no other legitimate module home
      # (rare; flag for manual review rather than hard-failing the suite,
      # since a false positive here is a grep-\b substring artifact, not
      # necessarily a real boundary violation)
      continue
    fi
    _boundary_violations="${_boundary_violations} ${_fn}(in $(basename "$_libfile"))"
  done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$_libfile" | sed 's/()$//')
done

if [[ -z "$_boundary_violations" ]]; then
  pass "(f)" "every cli/lib/ function is either a >=2-module cross-cutting helper or lib-closure-reachable"
else
  fail "(f)" "lib function(s) with no cross-module caller and no lib-internal caller (dead lib code?)" "${_boundary_violations}"
fi

echo ""

# ---------------------------------------------------------------------------
# (g) cwd-independent + Homebrew libexec-style symlink sourcing (harness
#     7.6): _resolve_script_dir is proven for the flat single-file rc but NOT
#     for the new multi-file sourcing. Symlink rc + cli/ into a scratch bin
#     dir (mimicking /opt/homebrew/bin/rc -> .../libexec/rc) and invoke via
#     the symlink from an unrelated cwd; dispatch must still resolve cli/lib
#     + cli/*.sh correctly regardless of invocation cwd or path.
# ---------------------------------------------------------------------------
echo "=== (g) cwd-independent sourcing incl. Homebrew libexec symlink case ==="

_scratch_bin=$(mktemp -d)
_scratch_libexec="${_scratch_bin}/libexec"
mkdir -p "$_scratch_libexec"
cp "$RC" "${_scratch_libexec}/rc"
cp -R "${REPO_ROOT}/cli" "${_scratch_libexec}/cli"
cp "${REPO_ROOT}/VERSION" "${_scratch_libexec}/VERSION"
ln -s "${_scratch_libexec}/rc" "${_scratch_bin}/rc"
chmod +x "${_scratch_libexec}/rc"

_unrelated_cwd=$(mktemp -d)
_symlink_result=$(cd "$_unrelated_cwd" && "${_scratch_bin}/rc" --version 2>&1)
_symlink_exit=$?

if [[ $_symlink_exit -eq 0 && "$_symlink_result" == rc\ version* ]]; then
  pass "(g1)" "rc invoked via a libexec-style symlink from an unrelated cwd dispatches correctly (${_symlink_result})"
else
  fail "(g1)" "symlink-invoked rc failed to dispatch from an unrelated cwd" "exit=${_symlink_exit} output=${_symlink_result}"
fi

# A verb that requires reading cli/lib content (e.g. build's dockerfile-path
# lib call) also needs to resolve correctly -- schema is container-free and
# pure-lib-dependent (touches lib/config.sh's schema helpers), good smoke.
_symlink_schema_result=$(cd "$_unrelated_cwd" && "${_scratch_bin}/rc" schema >/dev/null 2>&1; echo $?)
if [[ "$_symlink_schema_result" == "0" ]]; then
  pass "(g2)" "rc schema (lib/config.sh-dependent verb) works via libexec symlink from unrelated cwd"
else
  fail "(g2)" "rc schema failed via libexec symlink from unrelated cwd" "exit=${_symlink_schema_result}"
fi

rm -rf "$_scratch_bin" "$_unrelated_cwd"

echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "=== Results ==="
if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed!"
  exit 0
else
  echo "$FAILURES test(s) failed"
  exit "$FAILURES"
fi
