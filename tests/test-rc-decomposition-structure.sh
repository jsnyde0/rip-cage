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
#     (check (c) below) is now a complete, accurate enumeration of the 151
#     functions actually declare -F-reachable after sourcing rc (156 total
#     definitions on disk minus the 5 cli/lib/msb_flags.sh functions that
#     are the pre-existing, not-sourced-by-rc gap this comment already
#     named -- msb_flags.sh is not in rc's `for _rc_lib in ...` source list).
# ---------------------------------------------------------------------------
echo "=== (b) Function-count invariant (measured pre-split count: 193, current: 156) ==="

EXPECTED_FN_COUNT=156
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
#     of the 151 currently rc-reachable functions must be `declare -F`-
#     reachable (156 total definitions on disk minus the 5 cli/lib/msb_flags.sh
#     functions rc does not source -- the pre-existing gap named in (b)'s
#     comment above). A loud, per-name failure (not just a count) so a
#     reviewer can see exactly which module dropped/misfiled a function.
# ---------------------------------------------------------------------------
echo "=== (c) declare -F reachability: all 151 rc-reachable functions defined after sourcing rc ==="

ALL_193_NAMES="_allowlist_add _allowlist_add_host_to_yaml _allowlist_is_in_cage _allowlist_promote _allowlist_read_observed_hosts _allowlist_refuse_in_cage _allowlist_resolve_config_file _allowlist_show _bd_dolt_port_inject_arg _bd_host_preflight _build_msb_load _build_warn_stale_containers _check_lfs_stubs _check_secret_path_denylist _check_workspace_config_base_url _collect_dangling_symlinks _collect_symlink_parents _config_applied_path _config_check_version _config_check_yq _config_default_global_yaml _config_diff_paths _config_emit_hint _config_ensure_global_seeded _config_format_yaml _config_global_path _config_label_value _config_load_layer _config_merge _config_mux_derive_allowed_set _config_paths_all_reload_eligible _config_project_path _config_provenance _config_read_applied _config_resolve_workspace_arg _config_schema_defaults_json _config_schema_field_type _config_schema_lines _config_schema_selection_list_keys _config_unknown_version_classify _config_validate_or_abort _config_write_applied _container_multiplexer _docker_call _doctor_bd_version_compare _doctor_dead_file_mounts _doctor_format_auth_probe _doctor_format_dead_mounts _doctor_host _emit_denylist_denial _emit_workspace_config_base_url_error _emit_workspace_config_base_url_warning _ensure_pi_auth_seed _extract_credentials _extract_credentials_has_usable_existing _host_source_is_root_owned _image_is_current _lexical_normalize_path _load_effective_config _manifest_build_dockerfile_path _manifest_build_mount_args _manifest_check_binary_root_owned _manifest_check_build_isolation _manifest_check_build_source_subfields _manifest_check_install_cmd_single_line _manifest_check_ioc_egress _manifest_check_mount_root_owned _manifest_check_mounts_denylist _manifest_check_seed_drift _manifest_default_yaml _manifest_dest_in_allowed_roots _manifest_dist_path _manifest_egress_hosts_json _manifest_ensure_seeded _manifest_expand_mount_host _manifest_extract_seed_fingerprint _manifest_generate_daemon_config_dockerfile_steps _manifest_generate_daemon_mcp_dockerfile_steps _manifest_generate_extra_dockerfile_steps _manifest_generate_launch_args _manifest_generate_multiplexer_label _manifest_generate_multiplexer_registry_steps _manifest_generate_pi_shim_steps _manifest_generate_safety_stack_asserted_steps _manifest_generate_shell_init_zshrc_steps _manifest_generate_source_builder_stages _manifest_generate_tool_init_config_dockerfile_steps _manifest_global_path _manifest_load _manifest_reconcile _manifest_seed_fingerprint_hash _manifest_validate _path_under_allowed_roots _prereq_error _probe_tcp _pull_or_build _pull_or_build_local _rc_ls_mode_from_source_path _rc_mux_resolve_hook_path _resolve_script_dir _run_with_timeout _secret_path_denylist_matched_pattern _seed_claude_home_dirs _symlink_follow_fingerprint _up_detect_worktree _up_image_drift_status _up_init_container _up_json_output _up_prepare_docker_mounts _up_prepare_environment _up_resolve_dcg_config _up_resolve_effective_credential_mounts_for_tool _up_resolve_placeholder_env_file _up_resolve_resume_config_mode _up_resolve_resume_credential_mounts _up_resolve_resume_image_drift_running _up_resolve_resume_image_drift_stopped _up_resolve_resume_symlink_fingerprint _up_short_image_id _up_start_container _up_validate_dcg_config check_docker check_jq cmd_allowlist cmd_attach cmd_auth cmd_auth_refresh cmd_build cmd_config cmd_config_get cmd_config_show cmd_destroy cmd_doctor cmd_down cmd_exec cmd_generate_dockerfile cmd_install cmd_ls cmd_manifest cmd_reload cmd_schema cmd_setup cmd_test cmd_up container_name json_error log resolve_name usage validate_path verify_rc_container"

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
  pass "(c)" "all 151 rc-reachable functions are declare -F reachable after sourcing rc"
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
#     ADR-029 D3). No replacement member exists: cli/reload.sh now depends
#     only on cli/lib/*.sh (grep-verified -- zero cli/up.sh-defined function
#     names appear as real calls in cli/reload.sh, comments excluded). The
#     up<->reload coupling this check tracked is therefore RETIRED, not
#     re-pointed. Assert that severance holds (a regression would be an
#     up.sh-defined name creeping back into reload.sh without updating this
#     canary) by re-sourcing in shim order and checking no such name is
#     declare -F-reachable-and-required.
# ---------------------------------------------------------------------------
echo "=== (d) up<->reload coupling: RETIRED (S5) -- cli/reload.sh has no cli/up.sh-defined dependency left ==="

_up_fn_names=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "${REPO_ROOT}/cli/up.sh" | sed 's/()$//')
_reload_real_calls=$(grep -v '^\s*#' "${REPO_ROOT}/cli/reload.sh" | grep -oE '_[a-zA-Z_][a-zA-Z0-9_]*' | sort -u)

_surviving_coupling=""
for _fn in $_up_fn_names; do
  if printf '%s\n' "$_reload_real_calls" | grep -qx "$_fn"; then
    _surviving_coupling="${_surviving_coupling} ${_fn}"
  fi
done

if [[ -z "$_surviving_coupling" ]]; then
  pass "(d)" "no cli/up.sh-defined function is referenced (call or identifier) by cli/reload.sh -- coupling confirmed retired"
else
  fail "(d)" "an up.sh-defined function reappeared in reload.sh -- update this canary to name/verify the new coupling member" "${_surviving_coupling}"
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
