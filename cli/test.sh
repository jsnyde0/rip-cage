#!/usr/bin/env bash
# cli/test.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# rip-cage-tsf2.1 (msb migration epic rip-cage-tsf2): cmd_test's live-probe
# path REWRITTEN onto msb -- was docker inspect (workspace mount source
# discovery) + docker exec (in-guest safety/skills/bd/recipe-smoke checks).
# The workspace mount source is simply the cage's own rc.source.path label
# (msb's `--mount-dir <path>:/workspace` args are built FROM that path at
# create time, cli/up.sh's _up_prepare_docker_mounts -- so the label IS the
# mount source, no need to walk a Mounts array the way docker's inspect
# shape required).


# _test_floor_probe_missing_line NAME -- when the cage's image predates the floor
# probe (ADR-031 D5b), running it yields msb's ENOENT against the program name,
# which reads as a tooling failure rather than the real finding. Detect the case
# first and return a legible FAIL line naming the fix. Prints nothing and returns
# 1 when the probe IS present.
#
# An image with no probe is an image whose floor is unverified, so this is a FAIL
# and not a skip -- same posture init takes at boot.
_test_floor_probe_missing_line() {
  local _name="$1"
  if _msb_exec "$_name" -- test -x /usr/local/lib/rip-cage/floor-probe.sh >/dev/null 2>&1; then
    return 1
  fi
  echo "FAIL  [0] floor: probe-present — this cage's image has no /usr/local/lib/rip-cage/floor-probe.sh, so its containment floor is unverified (ADR-031 D5b). Rebuild the image with 'rc build' and recreate the cage."
  return 0
}


# _test_suite_exec NAME SUITE ARM -- run one baked in-guest suite. The host-tool
# suite also gets the line's port (rc's own constant, so the script holds no
# copy) and the arm the cage's rc.host-tools label selects (present|absent).
_test_suite_exec() {
  local _name="$1" _suite="$2" _arm="$3"
  if [[ "$_suite" == "test-host-tool.sh" ]]; then
    _msb_exec "$_name" -e "RC_HOST_TOOL_PORT=${RC_HOST_TOOL_PORT}" -e "RC_HOST_TOOLS_DECLARED=${_arm}" -- "/usr/local/lib/rip-cage/${_suite}"
  else
    _msb_exec "$_name" -- "/usr/local/lib/rip-cage/${_suite}"
  fi
}

# _test_host_tools_host_half NAME -- the declared arm's host-side check (ADR-032
# D7 (a)): the client's list, taken through rc test's own exec at the absolute
# path, names the same tools and verbs as <state>/tools.json -- what the RUNNING
# gatekeeper loaded, never the file on disk (a changed file is doctor's contents
# drift, not a test failure). Retries on busy for up to 30 s (RC_TEST_LIST_BUSY_SECS
# shortens it for the hermetic test). Prints PASS/FAIL lines naming no tool or
# verb; returns 1 on a FAIL. Calls no declared verb and stops nothing.
# _test_ht_counts JSON -- "N tool(s)/M verb(s)" from a [[tool,[verbs]]] array, or
# "unreadable" when it is not one. Counts only: rc names no tool (ADR-005 D12).
_test_ht_counts() {
  jq -r '"\(length) tool(s)/\([.[][1] | length] | add // 0) verb(s)"' <<<"${1:-}" 2>/dev/null || echo unreadable
}

_test_host_tools_host_half() {
  local _name="$1" _sd _tj _out _rc _i=0 _max=30
  local _jq_listed='[.result.tools // {} | to_entries[] | [.key, (.value | keys)]] | sort'
  local _jq_loaded='[.tools // {} | to_entries[] | [.key, (.value.verbs // {} | keys)]] | sort'
  local _got _want _ntools _nverbs
  if [[ -n "${RC_TEST_LIST_BUSY_SECS:-}" ]]; then
    if [[ "${RC_TEST_LIST_BUSY_SECS}" =~ ^[0-9]+$ ]]; then
      _max="${RC_TEST_LIST_BUSY_SECS}"
    else
      echo "rc test: RC_TEST_LIST_BUSY_SECS='${RC_TEST_LIST_BUSY_SECS}' is not a non-negative integer; using 30" >&2
    fi
  fi
  _sd=$(_up_host_tools_cage_state_dir "$_name")
  _tj="${_sd}/tools.json"
  if [[ ! -f "$_tj" ]]; then
    echo "FAIL  [0] host-tools: list matches the running gatekeeper's declaration — ${_tj} is missing, so there is no record of what the gatekeeper loaded; run rc up"
    return 1
  fi
  while :; do
    _rc=0
    _out=$(_msb_exec "$_name" -- /usr/local/bin/host-tool --list --json 2>&1) || _rc=$?
    if [[ "$_rc" -eq 4 && "$_out" == *'"busy"'* && "$_i" -lt "$_max" ]]; then
      sleep 1
      _i=$((_i + 1))
      continue
    fi
    break
  done
  if [[ "$_rc" -eq 4 && "$_out" == *'"busy"'* ]]; then
    echo "FAIL  [0] host-tools: list matches the running gatekeeper's declaration — saturated line: the gatekeeper answered busy for ${_max} s"
    return 1
  fi
  if [[ "$_rc" -ne 0 ]]; then
    echo "FAIL  [0] host-tools: list matches the running gatekeeper's declaration — host-tool --list exited ${_rc}: $(printf '%s' "$_out" | head -1)"
    return 1
  fi
  _got=$(jq -c "$_jq_listed" <<<"$_out" 2>/dev/null) || _got=""
  _want=$(jq -c "$_jq_loaded" "$_tj" 2>/dev/null) || _want=""
  if [[ -z "$_got" || -z "$_want" || "$_got" != "$_want" ]]; then
    echo "FAIL  [0] host-tools: list does not match the running gatekeeper's declaration — list has $(_test_ht_counts "$_got"), loaded has $(_test_ht_counts "$_want") (names withheld; compare host-tool --list inside the cage with ${_tj})"
    return 1
  fi
  _ntools=$(jq 'length' <<<"$_want")
  _nverbs=$(jq '[.[][1] | length] | add // 0' <<<"$_want")
  echo "PASS  [0] host-tools: list matches the running gatekeeper's declaration — ${_ntools} tool(s), ${_nverbs} verb(s)"
}


cmd_test() {
  if [[ "${1:-}" == "--host" ]]; then
    shift
    exec "${SCRIPT_DIR}/tests/run-host.sh" "$@"
  fi
  if [[ "${1:-}" == "--e2e" ]]; then
    shift
    local e2e_script="${SCRIPT_DIR}/tests/test-e2e-lifecycle.sh"
    if [[ ! -f "$e2e_script" ]]; then
      echo "Error: test-e2e-lifecycle.sh not found (expected in a full rip-cage checkout)" >&2
      exit 1
    fi
    exec "$e2e_script" "$@"
  fi
  if [[ "${1:-}" == "--e2e-security" ]]; then
    shift
    local sec_script="${SCRIPT_DIR}/tests/test-security-model-injection.sh"
    if [[ ! -f "$sec_script" ]]; then
      echo "Error: test-security-model-injection.sh not found" >&2
      exit 1
    fi
    exec "$sec_script" "$@"
  fi
  local name
  name=$(resolve_name "${1:-}") || exit 1
  verify_rc_container "$name"

  # ADR-007 D9: host-side bd connectivity check — discover beads_dir from the
  # container's /workspace mount source, then invoke _bd_host_preflight in
  # --test-mode to get a PASS|FAIL [0] beads-host-dolt — <detail> line.
  local ws_source
  ws_source=$(_msb_label "$name" "rc.source.path" 2>/dev/null || true)
  # _beads_redirect_refusal rule 6 reads _UP_CONF_DIR, which rc up sets from the
  # config it launched with. Set it from the cage's rc.cage-conf label so this
  # check sees the same --conf directory (ADR-032 D2; rip-cage-jdl2.3.1 note).
  local _tc_conf
  _tc_conf=$(_msb_label "$name" "rc.cage-conf" 2>/dev/null || true)
  if [[ -n "$_tc_conf" ]]; then
    _UP_CONF_DIR="$(dirname "$(_protected_paths_walk_path "$_tc_conf" 2>/dev/null || printf '%s' "$_tc_conf")")"
  else
    _UP_CONF_DIR=""
  fi
  local preflight_beads_dir="" preflight_dolt_mode=""
  local preflight_skip_line=""  # if set, skip _bd_host_preflight and use this line
  if [[ -n "$ws_source" ]]; then
    preflight_beads_dir="${ws_source}/.beads"
    # Mirror cli/up.sh's beads resolution, so this check probes the .beads dir
    # the cage actually mounts: .beads/redirect first, then the worktree
    # auto-redirect (ADR-007 D6). Where up.sh ignores a redirect with a warning
    # (absolute path, control chars, target does not resolve), it keeps the
    # workspace's own .beads, and so does this. Where up.sh refuses to launch,
    # this reports the same reason as a FAIL.
    if [[ -f "${preflight_beads_dir}/redirect" ]]; then
      local redirect_target
      redirect_target=$(cat "${preflight_beads_dir}/redirect")
      if [[ "$redirect_target" != /* ]] && [[ ! "$redirect_target" =~ [[:cntrl:]] ]]; then
        local resolved_redirect redirect_refusal redirect_status=0
        resolved_redirect=$(realpath "${ws_source}/${redirect_target}" 2>/dev/null || true)
        if [[ -n "$resolved_redirect" && -d "$resolved_redirect" ]]; then
          # The rule rc up refuses to launch on, from its one home; status 2
          # reasons carry their own advice.
          redirect_refusal=$(_beads_redirect_refusal "$resolved_redirect") || redirect_status=$?
          if [[ "$redirect_status" -eq 1 ]]; then
            preflight_skip_line="FAIL [0] beads-host-dolt — .beads/redirect (${preflight_beads_dir}/redirect) is refused: ${redirect_refusal}. rc up refuses to launch with it; point the redirect at the main repo's .beads, or delete it."
          elif [[ "$redirect_status" -ne 0 ]]; then
            preflight_skip_line="FAIL [0] beads-host-dolt — .beads/redirect (${preflight_beads_dir}/redirect) is refused: ${redirect_refusal}. rc up refuses to launch with it."
          else
            preflight_beads_dir="$resolved_redirect"
          fi
        fi
      fi
    elif [[ -f "${ws_source}/.git" ]]; then
      # Worktree detection: check for auto-redirect condition (D6 semantics)
      _up_detect_worktree "$ws_source" >/dev/null 2>&1
      # wt_detected and wt_main_beads are globals set by _up_detect_worktree (cli/up.sh).
      # shellcheck disable=SC2154
      if [[ "$wt_detected" == "true" ]] \
         && [[ ! -f "${preflight_beads_dir}/dolt-server.port" ]] \
         && [[ ! -d "${preflight_beads_dir}/dolt" ]] \
         && [[ ! -d "${preflight_beads_dir}/embeddeddolt" ]]; then
        local resolved_main_beads
        resolved_main_beads=$(realpath "$wt_main_beads" 2>/dev/null || true)
        # up.sh's posture here is warn-and-skip, not refuse: a missing or
        # protected main-repo .beads leaves the worktree's own .beads mounted.
        if [[ -n "$resolved_main_beads" && -d "$resolved_main_beads" ]] \
           && ! _protected_paths_path_match "$resolved_main_beads" >/dev/null \
           && ! _mount_src_exposes_secrets_dir "$resolved_main_beads"; then
          preflight_beads_dir="$resolved_main_beads"
        fi
      fi
    fi
    if [[ -z "$preflight_skip_line" ]] && [[ -f "${preflight_beads_dir}/metadata.json" ]]; then
      preflight_dolt_mode=$(jq -r '.dolt_mode // empty' "${preflight_beads_dir}/metadata.json" 2>/dev/null || true)
    fi
  fi

  # Capture the host-side preflight line
  local preflight_line
  if [[ -n "$preflight_skip_line" ]]; then
    preflight_line="$preflight_skip_line"
  elif [[ -n "$preflight_beads_dir" ]]; then
    preflight_line=$(_bd_host_preflight "$preflight_beads_dir" "$preflight_dolt_mode" --test-mode 2>/dev/null) || true
  else
    preflight_line="PASS [0] beads-host-dolt — workspace mount not found (skipped)"
  fi

  # The in-guest suites, listed once for both output arms. The floor probe
  # (ADR-031 D5b) runs FIRST, for the same reason init runs it first: when the
  # image's floor is broken, that is the finding. A missing probe is reported as
  # a FAIL line (overall_rc=1) and the probe is left out of the run.
  local floor_missing_line="" overall_rc=0
  local suites=(floor-probe.sh test-safety-stack.sh test-skills.sh test-bd-roundtrip.sh run-recipe-smokes.sh test-host-tool.sh)
  if floor_missing_line=$(_test_floor_probe_missing_line "$name"); then
    suites=("${suites[@]:1}")
    overall_rc=1
  else
    floor_missing_line=""
  fi

  # ADR-032 D7: the arm is keyed on the cage's rc.host-tools label (the route
  # it actually has), not on the file. Under presence drift say so, then run
  # the arm the label selects. The declared arm's host-side list check runs
  # here; the in-guest half is the baked test-host-tool.sh in the suite list.
  local ht_arm ht_drift ht_lines="" ht_fail=0
  ht_arm=$(_up_host_tools_label_value "$name")
  ht_drift=$(_host_tools_presence_drift "$name")
  if [[ -n "$ht_drift" ]]; then
    log "INFO  host-tools: $(_host_tools_drift_text "$ht_drift")"
  fi
  if [[ "$ht_arm" == "present" ]]; then
    ht_lines=$(_test_host_tools_host_half "$name") || ht_fail=1
    [[ "$ht_fail" -ne 0 ]] && overall_rc=1
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local output="$floor_missing_line"
    # Each suite runs on its own so its exit status is captured: a suite that
    # crashes without printing a FAIL line would otherwise parse as green. A
    # non-zero exit injects a synthetic FAIL line so the JSON overall goes
    # "fail" even when stdout parsing sees only passing lines (anti-swallow).
    local suite suite_output suite_rc
    for suite in "${suites[@]}"; do
      suite_rc=0
      suite_output=$(_test_suite_exec "$name" "$suite" "$ht_arm" 2>&1) || suite_rc=$?
      output="${output}
${suite_output}"
      if [[ "$suite_rc" -ne 0 ]]; then
        if [[ "$suite" == "run-recipe-smokes.sh" ]]; then
          output="${output}
FAIL  [0] run-recipe-smokes: runner exited ${suite_rc} (one or more recipe smoke tests failed)"
        else
          output="${output}
FAIL  [0] ${suite%.sh}: suite exited ${suite_rc} — a suite that exits non-zero failed, whether or not it printed a FAIL line"
        fi
      fi
    done
    # Prepend host-side preflight line so the parse loop handles it uniformly
    output="${preflight_line}
${ht_lines}
${output}"
    # Parse PASS/FAIL lines into JSON array
    local checks="[]" overall="pass"
    while IFS= read -r line; do
      if [[ "$line" =~ ^(PASS|FAIL)[[:space:]]+\[([0-9]+)\][[:space:]]+(.*) ]]; then
        local status
        status=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')  # lowercase (bash 3.2 compat)
        local desc="${BASH_REMATCH[3]}"
        local test_name
        test_name="${desc%% — *}"
        local detail=""
        if [[ "$desc" == *" — "* ]]; then
          detail="${desc#* — }"
        fi
        checks=$(echo "$checks" | jq --arg name "$test_name" --arg status "$status" --arg detail "$detail" \
          '. + [{name: $name, status: $status, detail: $detail}]')
        [[ "$status" == "fail" ]] && overall="fail"
      fi
    done <<< "$output"
    jq -nc --arg name "$name" --argjson checks "$checks" --arg overall "$overall" \
      '{name: $name, checks: $checks, overall: $overall}'
    # Exit status agrees with .overall: any FAIL line, parsed or synthetic, fails it.
    [[ "$overall" == "pass" ]] || return 1
  else
    echo "$preflight_line"
    # Run every suite unconditionally and collect each exit status: rc runs
    # `set -euo pipefail`, so a bare call would abort on the first suite that
    # exits non-zero and later suites would never run. Mirrors the json arm.
    local suite suite_rc
    [[ -n "$floor_missing_line" ]] && echo "$floor_missing_line"
    [[ -n "$ht_lines" ]] && echo "$ht_lines"
    for suite in "${suites[@]}"; do
      suite_rc=0
      _test_suite_exec "$name" "$suite" "$ht_arm" || suite_rc=$?
      [[ "$suite_rc" -ne 0 ]] && overall_rc=1
    done
    return "$overall_rc"
  fi
}

