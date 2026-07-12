#!/usr/bin/env bash
# cli/test.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_test() {
  if [[ "${1:-}" == "--host" ]]; then
    shift
    exec "${SCRIPT_DIR}/tests/run-host.sh" "$@"
  fi
  if [[ "${1:-}" == "--e2e" ]]; then
    shift
    local e2e_script="${SCRIPT_DIR}/tests/test-e2e-lifecycle.sh"
    if [[ ! -f "$e2e_script" ]]; then
      echo "Error: test-e2e-lifecycle.sh not found (create it via the e2e bead)" >&2
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
  ws_source=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/workspace" }}{{ .Source }}{{ end }}{{ end }}' "$name" 2>/dev/null || true)
  local preflight_beads_dir="" preflight_dolt_mode=""
  local preflight_skip_line=""  # if set, skip _bd_host_preflight and use this line
  if [[ -n "$ws_source" ]]; then
    preflight_beads_dir="${ws_source}/.beads"
    # Mirror D6 semantics (rc:881-931): check for .beads/redirect first,
    # then fall back to worktree auto-redirect with _path_under_allowed_roots guard.
    if [[ -f "${preflight_beads_dir}/redirect" ]]; then
      local redirect_target
      redirect_target=$(cat "${preflight_beads_dir}/redirect")
      if [[ "$redirect_target" == /* ]] || [[ "$redirect_target" =~ [[:cntrl:]] ]]; then
        # Absolute path or control chars — treat as outside allowed roots
        preflight_skip_line="PASS [0] beads-host-dolt — beads_dir outside allowed roots (skipped)"
      else
        local resolved_redirect
        resolved_redirect=$(realpath "${ws_source}/${redirect_target}" 2>/dev/null || true)
        if [[ -n "$resolved_redirect" && -d "$resolved_redirect" ]] \
           && _path_under_allowed_roots "$resolved_redirect"; then
          preflight_beads_dir="$resolved_redirect"
        else
          preflight_skip_line="PASS [0] beads-host-dolt — beads_dir outside allowed roots (skipped)"
        fi
      fi
    elif [[ -f "${ws_source}/.git" ]]; then
      # Worktree detection: check for auto-redirect condition (D6 semantics)
      local wt_git_dir wt_common_git
      wt_git_dir=$(git -C "$ws_source" rev-parse --git-dir 2>/dev/null || true)
      wt_common_git=$(git -C "$ws_source" rev-parse --git-common-dir 2>/dev/null || true)
      if [[ -n "$wt_common_git" ]] && [[ "$wt_common_git" != "$wt_git_dir" ]] \
         && [[ ! -f "${preflight_beads_dir}/dolt-server.port" ]] \
         && [[ ! -d "${preflight_beads_dir}/dolt" ]] \
         && [[ ! -d "${preflight_beads_dir}/embeddeddolt" ]]; then
        local main_repo_root="${wt_common_git%/.git}"
        local resolved_main_beads
        resolved_main_beads=$(realpath "${main_repo_root}/.beads" 2>/dev/null || true)
        if [[ -n "$resolved_main_beads" && -d "$resolved_main_beads" ]] \
           && _path_under_allowed_roots "$resolved_main_beads"; then
          preflight_beads_dir="$resolved_main_beads"
        else
          preflight_skip_line="PASS [0] beads-host-dolt — beads_dir outside allowed roots (skipped)"
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

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    local output
    output=$(docker exec "$name" bash -c \
      '/usr/local/lib/rip-cage/test-safety-stack.sh; /usr/local/lib/rip-cage/test-skills.sh; /usr/local/lib/rip-cage/test-bd-roundtrip.sh' 2>&1) || true
    # run-recipe-smokes.sh: run separately to capture non-zero exit AND stdout.
    # Its per-smoke PASS/FAIL lines are parsed by the loop below; additionally,
    # a non-zero runner exit injects a synthetic FAIL line so the JSON overall
    # goes "fail" even if stdout parsing sees only passing lines (anti-swallow).
    local smokes_output smokes_rc
    smokes_rc=0
    smokes_output=$(docker exec "$name" /usr/local/lib/rip-cage/run-recipe-smokes.sh 2>&1) || smokes_rc=$?
    if [[ "$smokes_rc" -ne 0 ]]; then
      smokes_output="${smokes_output}
FAIL  [0] run-recipe-smokes: runner exited ${smokes_rc} (one or more recipe smoke tests failed)"
    fi
    output="${output}
${smokes_output}"
    # Prepend host-side preflight line so the parse loop handles it uniformly
    output="${preflight_line}
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
  else
    echo "$preflight_line"
    docker exec "$name" /usr/local/lib/rip-cage/test-safety-stack.sh
    docker exec "$name" /usr/local/lib/rip-cage/test-skills.sh
    docker exec "$name" /usr/local/lib/rip-cage/test-bd-roundtrip.sh
    docker exec "$name" /usr/local/lib/rip-cage/run-recipe-smokes.sh
  fi
}

