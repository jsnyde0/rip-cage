#!/usr/bin/env bash
# cli/lib/host_tools.sh -- the host-tool declaration loader (ADR-032 D2/D3).
#
# A project's host tools are declared in a host-side sibling file,
# <config-stem>.tools.yaml, beside the cage's resolved config. This lib finds
# that file and loads it: schema, typed slots, argv[0] and path-carrying
# literal checks against the mount list the caller supplies. It is pure
# host-side text processing: it creates nothing and runs no tool. Everything
# downstream (the gatekeeper, rc up) reads the declaration through
# _host_tools_load.
#
# Sourced by rc (explicit lib list); needs cli/lib/protected_paths.sh (the
# path walker and the yq/jq prerequisite check) and, for the inspect reader,
# cli/lib/msb_runtime.sh. Bash 3.2 only (ADR-008 D5): no bash-4 builtins or arrays.

# The vsock port the line listens on (ADR-032 D6).
# shellcheck disable=SC2034  # consumed by the gatekeeper and rc up wiring (rip-cage-jdl2.2/.3)
RC_HOST_TOOL_PORT=7700

# _host_tools_file CAGE RESOLVED_CONF -- the declaration path. Beside the
# config FILE's real path (ADR-032 D2: a symlink on the file itself is
# followed, as is any symlinked directory; a nonexistent directory still
# yields an absolute path through the walker), the last extension of the real
# basename swapped for .tools.yaml; with no config path, the default
# projects directory, spelled out. There is no override variable: the sibling
# rule is the only lookup, so every locator finds the same file.
_host_tools_file() {
  local _cage="$1" _conf="${2:-}" _real _base
  if [[ -z "${_conf}" ]]; then
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/rip-cage/projects/${_cage}.tools.yaml"
    return 0
  fi
  # exit 2 (dangling) still prints the best lexical resolution; use it.
  _real="$(_protected_paths_walk_path "${_conf}")" || true
  _base="$(basename "${_real}")"
  printf '%s/%s.tools.yaml\n' "$(dirname "${_real}")" "${_base%.*}"
}

# _host_tools_present CAGE RESOLVED_CONF -- "present" or "absent", always exit 0.
_host_tools_present() {
  local _f
  _f="$(_host_tools_file "$1" "${2:-}")"
  if [[ -e "${_f}" ]]; then echo present; else echo absent; fi
}

# _host_tools_mounts_from_inspect CAGE -- the host source of every mount msb
# recorded for an existing cage, one per line. Non-zero, no output, when the
# cage does not exist.
_host_tools_mounts_from_inspect() {
  local _raw
  _raw="$(_msb_inspect_json "$1")" || return 1
  jq -r '.config.mounts[]?.host // empty' <<<"${_raw}"
}

# _host_tools_resolve_path ABS_PATH -- the path walker shared with the
# authority-directory predicate; exit 2 on a dangling symlink or a loop.
_host_tools_resolve_path() {
  _protected_paths_walk_path "$@"
}

# The jq program: schema validation and normalization in one pass. A defect is
# raised with error({loc, msg}) and caught as {"__err": {loc, msg}}; the first
# one raised wins. Unknown keys are refused at every level.
#
# Known residue (for the cage-config skill, not detectable here): a duplicate
# YAML key is resolved last-wins by yq before this program sees the document,
# so `argv:` written twice loads as the second one. The skill's instruction is
# to write each key once.
_HT_JQ=''
IFS= read -r -d '' _HT_JQ <<'EOF' || true
def fail($loc; $msg): error({loc: $loc, msg: $msg});
def jk: if test("[:\\s]") then tojson else . end;
def j($a; $b): [$a, ($b | jk)] | map(select(. != "")) | join(".");
def isstr: type == "string";
def isint: type == "number" and (tojson | test("^-?[0-9]+$"));
def hasctl: isstr and test("[\u0000-\u001f\u007f-\u009f]");
def isname: isstr and test("^[a-z][a-z0-9_-]{0,31}$");
def isph: isstr and test("^\\{[a-z][a-z0-9_-]{0,31}\\}$");
def hasph: isstr and test("\\{[a-z][a-z0-9_-]{0,31}\\}");
def keys_ok($loc; $allowed):
  ((keys_unsorted - $allowed)[0]) as $bad
  | if $bad != null then fail(j($loc; $bad); "unknown key (not valid here)") else . end;
def bool_or($loc; $k; $d):
  if has($k) then (if (.[$k] | type) == "boolean" then . else fail(j($loc; $k); "must be a boolean") end)
  else .[$k] = $d end;

def slot_string($loc):
  keys_ok($loc; ["type", "max", "regex", "allow_dash", "allow_slash", "default"])
  | (if has("max") then (if (.max | isint) and .max >= 1 then . else fail(j($loc; "max"); "must be a JSON integer >= 1") end) else .max = 4096 end)
  | (if has("regex") then
       (if (.regex | isstr) then . else fail(j($loc; "regex"); "must be a string") end)
       | (.regex as $re | (try ("" | test($re) | "ok") catch "bad") as $r
          | if $r == "ok" then . else fail(j($loc; "regex"); "regex does not compile") end)
     else . end)
  | bool_or($loc; "allow_dash"; false)
  | bool_or($loc; "allow_slash"; false)
  | (if has("default") then
       . as $s
       | (if ($s.default | isstr) then . else fail(j($loc; "default"); "default must be a string") end)
       | (if ($s.default | hasctl) then fail(j($loc; "default"); "default contains a control character") else . end)
       | (if ($s.default | utf8bytelength) <= $s.max then . else fail(j($loc; "default"); "default is longer than max") end)
       | (if ($s | has("regex")) and (($s.default | test("^(?:" + $s.regex + ")$")) | not)
          then fail(j($loc; "default"); "default does not match the slot's regex") else . end)
       | (if ($s.allow_dash | not) and ($s.default | startswith("-"))
          then fail(j($loc; "default"); "default begins with - but allow_dash is false") else . end)
       | (if ($s.allow_slash | not) and ($s.default | contains("/"))
          then fail(j($loc; "default"); "default contains / but allow_slash is false") else . end)
       | (if ($s.allow_slash | not) and ($s.default == "..")
          then fail(j($loc; "default"); "default is the .. segment but allow_slash is false") else . end)
     else . end)
  | {type, max, allow_dash, allow_slash}
    + (if has("regex") then {regex} else {} end)
    + (if has("default") then {default} else {} end);

def slot_int($loc):
  keys_ok($loc; ["type", "min", "max", "default"])
  | (if has("min") and (.min | isint | not) then fail(j($loc; "min"); "must be a JSON integer") else . end)
  | (if has("max") and (.max | isint | not) then fail(j($loc; "max"); "must be a JSON integer") else . end)
  | (if has("min") and has("max") and .min > .max then fail($loc; "min is greater than max") else . end)
  | (if has("default") then
       (if (.default | isint) then . else fail(j($loc; "default"); "default must be a JSON integer") end)
       | (if (has("min") and .default < .min) or (has("max") and .default > .max)
          then fail(j($loc; "default"); "default is outside min..max") else . end)
     else . end)
  | {type}
    + (if has("min") then {min} else {} end)
    + (if has("max") then {max} else {} end)
    + (if has("default") then {default} else {} end);

def slot_enum($loc):
  keys_ok($loc; ["type", "values", "default"])
  | (if has("values") then . else fail(j($loc; "values"); "required") end)
  | (if (.values | type) == "array" and (.values | length) > 0 and (.values | all(isstr))
     then . else fail(j($loc; "values"); "must be a non-empty array of strings") end)
  | (if (.values | any(hasctl)) then fail(j($loc; "values"); "a value contains a control character") else . end)
  | (if ((.values | unique | length) == (.values | length)) then . else fail(j($loc; "values"); "duplicate values") end)
  | (if has("default") then
       (.default as $d
        | if ($d | isstr) and any(.values[]; . == $d) then .
          else fail(j($loc; "default"); "default must be one of values") end)
     else . end)
  | {type, values} + (if has("default") then {default} else {} end);

def slot($loc):
  (if type != "object" then fail($loc; "must be a map") else . end)
  | (if has("type") then . else fail(j($loc; "type"); "required") end)
  | (if (.type == "string" or .type == "int" or .type == "enum") then . else fail(j($loc; "type"); "must be one of string, int, enum") end)
  | if .type == "string" then slot_string($loc)
    elif .type == "int" then slot_int($loc)
    else slot_enum($loc) end;

def verb($loc):
  (if type != "object" then fail($loc; "must be a map") else . end)
  | keys_ok($loc; ["argv", "slots", "timeout", "returns_secret"])
  | (if has("argv") then . else fail(j($loc; "argv"); "required") end)
  | (if (.argv | type) == "array" and (.argv | length) > 0 then . else fail(j($loc; "argv"); "must be a non-empty array of strings") end)
  | (.argv | to_entries) as $els
  | ($els | map(select(.value | isstr | not))[0]) as $nonstr
  | (if $nonstr != null then fail(j($loc; "argv[\($nonstr.key)]"); "must be a string") else . end)
  | ($els | map(select(.value | hasctl))[0]) as $ctl
  | (if $ctl != null then fail(j($loc; "argv[\($ctl.key)]"); "argv element contains a control character") else . end)
  | ($els | map(select(.value | isph))) as $phs
  | ($els | map(select((.value | isph | not) and (.value | hasph)))) as $emb
  | (if ($phs | length) > 0 and $phs[0].key == 0 then fail(j($loc; "argv[0]"); "a placeholder cannot be argv[0]") else . end)
  | (if ($emb | length) > 0 then fail(j($loc; "argv[\($emb[0].key)]"); "embedded placeholder; a placeholder must be a whole argv element (ADR-032 D3)") else . end)
  | (if has("slots") then (if (.slots | type) == "object" then . else fail(j($loc; "slots"); "must be a map") end) else .slots = {} end)
  | .slots = (.slots | to_entries | map(. as $e
      | (if ($e.key | isname) then . else fail(j(j($loc; "slots"); $e.key); "bad slot name (must match ^[a-z][a-z0-9_-]{0,31}$)") end)
      | .value = ($e.value | slot(j(j($loc; "slots"); $e.key)))) | from_entries)
  | . as $v
  | ($phs | map(select(. as $p | ($v.slots | has($p.value[1:-1])) | not))[0]) as $nosl
  | (if $nosl != null then fail(j($loc; "argv[\($nosl.key)]"); "placeholder \($nosl.value) has no slot") else . end)
  | ($v.slots | keys_unsorted | map(. as $n | {n: $n, hits: ($phs | map(select(.value == ("{" + $n + "}"))))})) as $uses
  | ($uses | map(select(.hits | length == 0))[0]) as $unused
  | (if $unused != null then fail(j(j($loc; "slots"); $unused.n); "slot has no placeholder in argv") else . end)
  | ($uses | map(select(.hits | length > 1))[0]) as $twice
  | (if $twice != null then fail(j($loc; "argv[\($twice.hits[1].key)]"); "slot \($twice.n) is used twice; each slot must appear exactly once") else . end)
  | (if has("timeout") then . else fail(j($loc; "timeout"); "required") end)
  | (if (.timeout | isstr) and (.timeout | test("^[0-9]{1,9}[sm]$")) and ((.timeout[:-1] | tonumber) > 0)
     then . else fail(j($loc; "timeout"); "must be <n>s or <n>m with n a positive integer of at most 9 digits") end)
  | .timeout = ((.timeout[:-1] | tonumber) * (if (.timeout | endswith("m")) then 60 else 1 end))
  | bool_or($loc; "returns_secret"; false)
  | {argv, slots, timeout, returns_secret};

def tool($loc):
  (if type != "object" then fail($loc; "must be a map") else . end)
  | keys_ok($loc; ["verbs"])
  | (if has("verbs") then . else fail(j($loc; "verbs"); "required") end)
  | (if (.verbs | type) == "object" then . else fail(j($loc; "verbs"); "must be a map") end)
  | {verbs: (.verbs | to_entries | map(. as $e
      | (if ($e.key | isname) then . else fail(j(j($loc; "verbs"); $e.key); "bad verb name (must match ^[a-z][a-z0-9_-]{0,31}$)") end)
      | .value = ($e.value | verb(j(j($loc; "verbs"); $e.key)))) | from_entries)};

try (
  (if type != "object" then fail("(document)"; "must be a map with a tools key") else . end)
  | keys_ok(""; ["tools"])
  | (if has("tools") then . else fail("tools"; "required") end)
  | (if (.tools | type) == "object" then . else fail("tools"; "must be a map") end)
  | {v: 1, tools: (.tools | to_entries | map(. as $e
      | (if ($e.key | isname) then . else fail(j("tools"; $e.key); "bad tool name (must match ^[a-z][a-z0-9_-]{0,31}$)") end)
      | .value = ($e.value | tool(j("tools"; $e.key)))) | from_entries)}
) catch {__err: (if type == "object" then . else {loc: "(document)", msg: .} end)}
EOF

# Every non-placeholder argv element of a normalized document, as
# "LOCATION<TAB>ELEMENT" (control characters are refused upstream, so a line
# is one element).
_HT_JQ_ELEMENTS=''
IFS= read -r -d '' _HT_JQ_ELEMENTS <<'EOF' || true
.tools | to_entries[] | .key as $t | .value.verbs | to_entries[] | .key as $v
| .value.argv | to_entries[]
| select(.value | test("^\\{[a-z][a-z0-9_-]{0,31}\\}$") | not)
| "tools.\($t).verbs.\($v).argv[\(.key)]\t\(.value)"
EOF

# State shared by the check helpers below (set per _host_tools_load call).
_HT_ERR_MSG=''
_HT_MOUNTS=''   # "REALPATH<TAB>SOURCE" per line

# _host_tools_load_mounts MOUNT_LIST_FILE -- fill _HT_MOUNTS.
_host_tools_load_mounts() {
  local _line _real
  _HT_MOUNTS=''
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ -n "${_line}" ]] || continue
    # exit 2 (dangling) still prints the best lexical resolution; use it.
    _real="$(_host_tools_resolve_path "${_line}")" || true
    [[ -n "${_real}" ]] || _real="${_line}"
    _real="${_real%/}"
    _HT_MOUNTS="${_HT_MOUNTS}${_real}"$'\t'"${_line}"$'\n'
  done < "$1"
}

# _host_tools_mount_hit RESOLUTION -- print "SOURCE" and return 0 when
# RESOLUTION equals or lies inside any recorded mount.
_host_tools_mount_hit() {
  local _r="${1%/}" _m _src
  while IFS=$'\t' read -r _m _src; do
    [[ -n "${_src}" ]] || continue
    if [[ -z "${_m}" || "${_r}" == "${_m}" || "${_r}" == "${_m}"/* ]]; then
      printf '%s\n' "${_src}"
      return 0
    fi
  done <<<"${_HT_MOUNTS}"
  return 1
}

# _host_tools_scan_literal LOC ELEMENT -- ADR-032 D2 bullet 2 for one literal.
# Sets _HT_ERR_MSG and returns 1 on a refusal.
_host_tools_scan_literal() {
  local _el="$2" _rest _piece _more _i _ch _prev _cand _res _src _rc
  _rest="${_el}"
  _more=1
  while [[ "${_more}" == 1 ]]; do
    case "${_rest}" in
      *=*) _piece="${_rest%%=*}"; _rest="${_rest#*=}" ;;
      *) _piece="${_rest}"; _more=0 ;;
    esac
    # Relative-path shapes, even behind an option prefix (-I../x, @../x,
    # file:../x, -I~/x): ./ at the start, ~ at the start or before a /, and a
    # .. segment-ish run (../ anywhere, or a trailing ..). main..feature passes.
    if [[ "${_piece}" == ./* ]]; then
      _HT_ERR_MSG="element \"${_el}\" begins with ./; declare an absolute path outside every mount"
      return 1
    fi
    if [[ "${_piece}" == '~'* || "${_piece}" == *'~/'* ]]; then
      _HT_ERR_MSG="element \"${_el}\" contains ~; declare an absolute path outside every mount"
      return 1
    fi
    if [[ "${_piece}" == *../* || "${_piece}" == *.. ]]; then
      _HT_ERR_MSG="element \"${_el}\" contains a .. path segment; declare an absolute path outside every mount"
      return 1
    fi
    _i=0
    _prev=''
    while [[ "${_i}" -lt "${#_piece}" ]]; do
      _ch="${_piece:${_i}:1}"
      if [[ "${_ch}" == "/" && "${_prev}" != "/" ]]; then
        _cand="${_piece:${_i}}"
        _rc=0
        _res="$(_host_tools_resolve_path "${_cand}")" || _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
          _HT_ERR_MSG="element \"${_el}\" has a dangling symlink or a symlink loop (or a chain of more than 40 links) on \"${_cand}\"; the cage could create the target"
          return 1
        fi
        if _src="$(_host_tools_mount_hit "${_res}")"; then
          _HT_ERR_MSG="element \"${_el}\" resolves to ${_res}, inside mount source ${_src}"
          return 1
        fi
      fi
      _prev="${_ch}"
      _i=$((_i + 1))
    done
  done
  return 0
}

# _host_tools_fail FILE LOCATION MESSAGE -- the one Error: line. Control
# characters (newlines included) never reach the terminal.
_host_tools_fail() {
  local _f _l _m
  _f="$(printf '%s' "${1//$'\n'/ }" | tr -d '[:cntrl:]')"
  _l="$(printf '%s' "${2//$'\n'/ }" | tr -d '[:cntrl:]')"
  _m="$(printf '%s' "${3//$'\n'/ }" | tr -d '[:cntrl:]')"
  printf 'Error: host-tool declaration %s: %s: %s\n' "${_f}" "${_l}" "${_m}" >&2
}

# _host_tools_load FILE MOUNT_LIST_FILE
#   exit 0 + normalized JSON (one line) on stdout when FILE is valid;
#   exit 0 + empty output when FILE does not exist;
#   exit 1 + nothing on stdout + ONE "Error: " line on stderr on any defect.
# MOUNT_LIST_FILE: one host mount source per line, blank lines ignored.
_host_tools_load() {
  local _file="$1" _mlist="${2:-}"
  [[ -e "${_file}" ]] || return 0

  _protected_paths_check_deps || return 1
  if [[ -z "${_mlist}" || ! -r "${_mlist}" ]]; then
    _host_tools_fail "${_file}" "(mount list)" "cannot read the mount list file \"${_mlist}\""
    return 1
  fi

  local _raw _norm _err _ndocs
  if ! _ndocs="$(yq ea '[.] | length' "${_file}" 2>&1)"; then
    _host_tools_fail "${_file}" "(document)" "not valid YAML: ${_ndocs}"
    return 1
  fi
  if [[ "${_ndocs}" != "1" ]]; then
    _host_tools_fail "${_file}" "(document)" "declaration must be a single YAML document"
    return 1
  fi
  if ! _raw="$(yq -o=json '.' "${_file}" 2>&1)"; then
    _host_tools_fail "${_file}" "(document)" "not valid YAML: ${_raw}"
    return 1
  fi
  if [[ -z "${_raw}" ]]; then
    _host_tools_fail "${_file}" "(document)" "empty document; expected a map with a tools key"
    return 1
  fi
  if ! _norm="$(printf '%s\n' "${_raw}" | jq -c "${_HT_JQ}" 2>&1)"; then
    _host_tools_fail "${_file}" "(document)" "cannot be normalized: ${_norm}"
    return 1
  fi
  _err="$(jq -r 'if type == "object" and has("__err") then "1" else empty end' <<<"${_norm}")"
  if [[ -n "${_err}" ]]; then
    _host_tools_fail "${_file}" "$(jq -r '.__err.loc' <<<"${_norm}")" "$(jq -r '.__err.msg' <<<"${_norm}")"
    return 1
  fi

  _host_tools_load_mounts "${_mlist}"

  # The declaration file itself must not lie inside any mount.
  local _frc=0 _fres _fsrc
  _fres="$(_host_tools_resolve_path "${_file}")" || _frc=$?
  if [[ "${_frc}" -ne 0 ]]; then
    _host_tools_fail "${_file}" "(declaration file)" "cannot be resolved (dangling symlink or loop)"
    return 1
  fi
  if _fsrc="$(_host_tools_mount_hit "${_fres}")"; then
    _host_tools_fail "${_file}" "(declaration file)" "the declaration file resolves to ${_fres}, inside mount source ${_fsrc}"
    return 1
  fi

  # argv[0] and the literal scan, per element, first defect wins.
  local _elements _eloc _el _line
  if ! _elements="$(jq -r "${_HT_JQ_ELEMENTS}" <<<"${_norm}" 2>&1)"; then
    _host_tools_fail "${_file}" "(document)" "cannot list argv elements: ${_elements}"
    return 1
  fi
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] || continue
    _eloc="${_line%%$'\t'*}"
    _el="${_line#*$'\t'}"
    if [[ "${_eloc}" == *"argv[0]" ]]; then
      if [[ "${_el}" != /* ]]; then
        _host_tools_fail "${_file}" "${_eloc}" "argv[0] \"${_el}\" must be an absolute path"
        return 1
      fi
      if [[ ! -f "${_el}" ]]; then
        _host_tools_fail "${_file}" "${_eloc}" "argv[0] \"${_el}\" does not exist or is not a regular file"
        return 1
      fi
      if [[ ! -x "${_el}" ]]; then
        _host_tools_fail "${_file}" "${_eloc}" "argv[0] \"${_el}\" is not executable"
        return 1
      fi
    fi
    _HT_ERR_MSG=''
    if ! _host_tools_scan_literal "${_eloc}" "${_el}"; then
      _host_tools_fail "${_file}" "${_eloc}" "${_HT_ERR_MSG}"
      return 1
    fi
  done <<<"${_elements}"

  printf '%s\n' "${_norm}"
}

# ---------------------------------------------------------------------------
# rc up site-1 helpers (rip-cage-jdl2.3.1; ADR-032 D2, D6). Nothing here
# creates a directory or starts a process: the state directory is created by
# the gatekeeper-start section, only after every check has passed.
# ---------------------------------------------------------------------------

# _rc_state_root -- the directory every cage's state directory lives under:
# ${RC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rip-cage}, a relative
# RC_STATE_DIR resolved against $PWD once (the authority-directory predicate
# resolves it the same way, so the path a refusal names is the path in force).
_rc_state_root() {
  local _root="${RC_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/rip-cage}"
  [[ "${_root}" == /* ]] || _root="${PWD}/${_root}"
  # Canonical: ../ and symlinks resolved, so a refusal names the real path.
  _root="$(_protected_paths_walk_path "${_root}")" || true
  printf '%s\n' "${_root}"
}

# _rc_state_dir CAGE -- <state root>/<cage>.
_rc_state_dir() {
  printf '%s/%s\n' "$(_rc_state_root)" "$1"
}

# _rc_sun_path_max -- the usable unix-socket path length, sun_path less its
# NUL: 103 on Darwin, 107 elsewhere. The one place the number lives.
_rc_sun_path_max() {
  case "$(uname -s)" in
    Darwin) echo 103 ;;
    *) echo 107 ;;
  esac
}

# _rc_socket_path_check CAGE [CONTEXT] -- CONTEXT is the refusal clause saying
# what did and did not happen (site 1 default: before any msb call). Exit 1 + one Error: line naming RC_STATE_DIR
# when <state dir>/host-tool.sock is longer than the platform limit (bytes).
_rc_socket_path_check() {
  local _sock _max _len _ctx="${2:-Refusing to launch before any msb call}"
  _sock="$(_rc_state_dir "$1")/host-tool.sock"
  _max="$(_rc_sun_path_max)"
  _len="$(printf '%s' "${_sock}" | LC_ALL=C wc -c | tr -d ' ')"
  if [[ "${_len}" -gt "${_max}" ]]; then
    echo "Error: the host-tool socket path ${_sock} is ${_len} bytes, over this platform's ${_max}-byte unix-socket limit. Set RC_STATE_DIR to a shorter directory (the state directory holds the socket); ${_ctx}." >&2
    return 1
  fi
  return 0
}

# _host_tools_path_outside_mounts PATH MOUNTS_FILE -- the loader's mount-hit
# logic as a standalone check, for argv[0]-style paths. MOUNTS_FILE: one host
# mount source per line. Exit 0 when PATH's real path lies outside every
# mount; exit 1 + the matching mount source on stdout when it equals or lies
# inside one; exit 2 + nothing when PATH cannot be resolved (dangling link or
# loop). Fills _HT_MOUNTS (shared loader state).
_host_tools_path_outside_mounts() {
  local _p="$1" _mf="$2" _res _src _rc=0
  _host_tools_load_mounts "${_mf}"
  _res="$(_host_tools_resolve_path "${_p}")" || _rc=$?
  [[ "${_rc}" -eq 0 ]] || return 2
  if _src="$(_host_tools_mount_hit "${_res}")"; then
    printf '%s\n' "${_src}"
    return 1
  fi
  return 0
}

# _rc_python3 -- the interpreter rc execs: ${RC_PYTHON3:-$(command -v python3)}
# resolved to an absolute real path (symlinks followed). Exit 1 and nothing
# printed when there is none, or the name dangles or is not an executable file.
_rc_python3() {
  local _p="${RC_PYTHON3:-}" _real _rc=0
  if [[ -z "${_p}" ]]; then
    _p="$(command -v python3 2>/dev/null)" || _p=''
  elif [[ "${_p}" != */* ]]; then
    _p="$(command -v "${_p}" 2>/dev/null)" || _p=''
  fi
  [[ -n "${_p}" ]] || return 1
  _real="$(_host_tools_resolve_path "${_p}")" || _rc=$?
  [[ "${_rc}" -eq 0 && -f "${_real}" && -x "${_real}" ]] || return 1
  printf '%s\n' "${_real}"
}

# _rc_python3_check MOUNTS_FILE [CONTEXT] -- the host prerequisite (ADR-032 D6): the
# interpreter exists, lies outside every mount the cage gets (the mount check
# runs BEFORE the interpreter is executed: a script under a mount is code the
# cage can rewrite), and imports socket, json and subprocess under -I. One
# Error: line on refusal.
_rc_python3_check() {
  local _mf="$1" _py _src _rc=0 _want="${RC_PYTHON3:-python3}"
  local _ctx="${2:-Refusing to launch before any msb call}"
  if ! _py="$(_rc_python3)"; then
    echo "Error: python3 not found or not an executable file (looked for ${_want}). The host-tool line needs the Python 3 standard library on the host; install python3 or set RC_PYTHON3 to its path; ${_ctx} (ADR-032 D6)." >&2
    return 1
  fi
  _src="$(_host_tools_path_outside_mounts "${_py}" "${_mf}")" || _rc=$?
  if [[ "${_rc}" -eq 1 ]]; then
    echo "Error: python3 resolves to ${_py}, inside mount source ${_src}: host code the cage could rewrite. Set RC_PYTHON3 to an interpreter outside every mount; ${_ctx} (ADR-032 D6)." >&2
    return 1
  elif [[ "${_rc}" -ne 0 ]]; then
    echo "Error: python3 at ${_py} cannot be resolved against the mount list; ${_ctx} (ADR-032 D6)." >&2
    return 1
  fi
  if ! "${_py}" -I -c 'import socket, json, subprocess' >/dev/null 2>&1; then
    echo "Error: python3 at ${_py} cannot run 'import socket, json, subprocess' under -I (a stub, such as macOS without the Command Line Tools, counts as missing). Install Python 3 or set RC_PYTHON3; ${_ctx} (ADR-032 D6)." >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Gatekeeper start/stop section (rip-cage-jdl2.3.3; ADR-032 D6). The ONE
# implementation rc up, rc up --replace, rc destroy and the tests share. rc
# owns the launch, the lock, the stale-socket unlink and the stop; the
# gatekeeper (cli/lib/host-tool-gatekeeper.py) owns its own session, its
# environment and its teardown. An optional STATE_DIR argument names the
# directory a cage's route was created against (its rc.state-dir label);
# absent, the cage's default under the current state root. Every act under a
# directory first proves it is a real, symlink-free directory named after the
# cage (_host_tools_dir_ok): the path may have come from a label.
# ---------------------------------------------------------------------------

_HT_RECOVERY="To recover: stop the gatekeeper by hand (its pid is in <dir>/gatekeeper.pid) if one runs, then remove the directory yourself; rc will not act through a symlinked or mislabelled path."

# _host_tools_dir_ok CAGE DIR -- DIR is an absolute path none of whose
# components is a symlink (its real-path walk equals its spelling), whose
# basename is the cage name, and whose lock file, if any, is not a symlink.
# Returns 0 when DIR does not exist yet (nothing to act on); one Error: line
# and 1 otherwise. The symlink check and the later open of the lock are not
# atomic (bash has no O_NOFOLLOW); what bounds that window is that the state
# directory is 0700 and operator-owned, so only the operator can plant a link.
_host_tools_dir_ok() {
  local _cage="$1" _d="${2%/}" _real _rc=0
  if [[ "${_d}" != /* || "$(basename "${_d}")" != "${_cage}" ]]; then
    echo "Error: ${_d} is not an absolute state directory named ${_cage}; not touching it. ${_HT_RECOVERY}" >&2
    return 1
  fi
  _real="$(_protected_paths_walk_path "${_d}")" || _rc=$?
  if [[ "${_rc}" -ne 0 || "${_real%/}" != "${_d}" ]]; then
    echo "Error: ${_d} has a symlink on its path (resolves to ${_real:-nowhere}); not touching it. ${_HT_RECOVERY}" >&2
    return 1
  fi
  if [[ -L "${_d}/lock" ]]; then
    echo "Error: ${_d}/lock is a symlink; not touching ${_d}. ${_HT_RECOVERY}" >&2
    return 1
  fi
  return 0
}

# _host_tools_state_dir_create CAGE [STATE_DIR] -- the state directory, 0700.
# Called only after site 1 passed and only when a declaration is present;
# never under --dry-run (the caller's business).
_host_tools_state_dir_create() {
  local _d="${2:-$(_rc_state_dir "$1")}" _parent
  _d="${_d%/}"
  _parent="$(dirname "${_d}")"
  _host_tools_dir_ok "$1" "${_d}" || return 1
  if ! (umask 077; mkdir -p "${_parent}" "${_d}") 2>/dev/null || ! chmod 0700 "${_d}"; then
    echo "Error: cannot create the host-tool state directory ${_d}; nothing was started." >&2
    return 1
  fi
  _host_tools_dir_ok "$1" "${_d}"
}

# _host_tools_gatekeeper_pid CAGE [STATE_DIR] -- the pid in the pid file;
# non-zero and silent when there is none, it is unreadable, or not a number.
_host_tools_gatekeeper_pid() {
  local _d="${2:-$(_rc_state_dir "$1")}" _p
  [[ -f "${_d}/gatekeeper.pid" ]] || return 1
  _p="$(tr -d ' \n\t' < "${_d}/gatekeeper.pid" 2>/dev/null)" || return 1
  [[ "${_p}" =~ ^[0-9]+$ && "${_p}" -gt 1 ]] || return 1
  printf '%s\n' "${_p}"
}

# _host_tools_pidfile_check STATE_DIR -- a pid file that exists but cannot be
# read is an unknown owner: one Error: line naming it and non-zero, so the
# caller deletes nothing and starts nothing.
_host_tools_pidfile_check() {
  local _f="$1/gatekeeper.pid"
  if [[ -e "${_f}" || -L "${_f}" ]] && ! { : < "${_f}"; } 2>/dev/null; then
    echo "Error: ${_f} exists but cannot be read (check its permissions); the gatekeeper's owner is unknown, so nothing was signalled, removed or started." >&2
    return 1
  fi
  return 0
}

# _host_tools_pid_is_gatekeeper PID [STATE_DIR] -- the pid is live AND its
# command line is the gatekeeper's (with STATE_DIR: this cage's own, by its
# --socket path). A recycled pid is not ours to signal. Without ps, a live pid
# is taken as ours.
_host_tools_pid_is_gatekeeper() {
  local _cmd
  kill -0 "$1" 2>/dev/null || return 1
  # Never a bare `ps -o command=`: ps truncates the line to $COLUMNS (BSD ps to
  # the terminal width), which made a live gatekeeper read as dead.
  if [[ -r "/proc/$1/cmdline" ]]; then
    _cmd="$({ tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null)" || return 1
    [[ -n "${_cmd}" ]] || return 1   # a zombie has no command line
  else
    _cmd="$(env -u COLUMNS ps -ww -o command= -p "$1" 2>/dev/null)" || return 0
    [[ -n "${_cmd}" ]] || return 0
  fi
  [[ "${_cmd}" == *host-tool-gatekeeper.py* ]] || return 1
  [[ -z "${2:-}" || "${_cmd}" == *"${2%/}/host-tool.sock"* ]]
}

# _host_tools_gatekeeper_alive CAGE [STATE_DIR] -- the pid file names a live
# gatekeeper of this cage.
_host_tools_gatekeeper_alive() {
  local _pid _d="${2:-$(_rc_state_dir "$1")}"
  _pid="$(_host_tools_gatekeeper_pid "$1" "${_d}")" || return 1
  _host_tools_pid_is_gatekeeper "${_pid}" "${_d}"
}

# _host_tools_sock_probe PYTHON SOCKET -- a connect succeeds (something listens).
_host_tools_sock_probe() {
  "$1" -I -c 'import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sys.argv[1])' "$2" >/dev/null 2>&1
}

# _host_tools_lock_take STATE_DIR -- Linux: flock on fixed descriptor 9 (bash
# 3.2 has no {fd} form); macOS: mkdir lock.d carrying a pid file, stale when
# that pid is dead (an empty pid file is a lock just taken: live for 2 s).
# Waits up to 30 s. Pair with _host_tools_lock_release.
_host_tools_lock_take() {
  local _d="$1" _i=0 _holder _empty=0 _rc=0
  if [[ "$(uname -s)" == Darwin ]]; then
    while [[ "${_i}" -lt 150 ]]; do
      if mkdir "${_d}/lock.d" 2>/dev/null; then
        printf '%s\n' "$$" > "${_d}/lock.d/pid"
        return 0
      fi
      _holder="$(cat "${_d}/lock.d/pid" 2>/dev/null || true)"
      if [[ -z "${_holder}" ]]; then
        _empty=$((_empty + 1))
        [[ "${_empty}" -gt 10 ]] && rm -rf "${_d}/lock.d"
      elif ! kill -0 "${_holder}" 2>/dev/null; then
        rm -rf "${_d}/lock.d"
      else
        _empty=0
      fi
      sleep 0.2
      _i=$((_i + 1))
    done
    echo "Error: timed out after 30 s waiting for the host-tool lock ${_d}/lock.d (held by pid ${_holder:-unknown}); nothing was started." >&2
    return 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock not found on PATH; the host-tool line needs it on Linux to serialize rc up. Install util-linux's flock; nothing was started." >&2
    return 1
  fi
  if ! { exec 9>"${_d}/lock"; } 2>/dev/null; then
    echo "Error: cannot open the host-tool lock ${_d}/lock; nothing was started." >&2
    return 1
  fi
  flock -w 30 -E 200 9 || _rc=$?
  if [[ "${_rc}" -eq 0 ]]; then return 0; fi
  exec 9>&-
  if [[ "${_rc}" -eq 200 ]]; then
    echo "Error: timed out after 30 s waiting for the host-tool lock ${_d}/lock (another rc up holds it); nothing was started." >&2
  else
    echo "Error: flock failed on ${_d}/lock (exit ${_rc}); nothing was started." >&2
  fi
  return 1
}

# _host_tools_lock_release STATE_DIR
_host_tools_lock_release() {
  if [[ "$(uname -s)" == Darwin ]]; then
    rm -rf "$1/lock.d"
  else
    exec 9>&-
  fi
}

# _host_tools_gatekeeper_stop_unlocked CAGE STATE_DIR -- SIGTERM the pid in the
# pid file, wait up to 5 s, then a further 5 s, then SIGKILL; remove the socket
# and the pid file. tools.json stays until destroy. Non-zero (and nothing
# removed) only when the pid file cannot be read. The caller holds the lock.
_host_tools_gatekeeper_stop_unlocked() {
  local _d="$2" _pid _i
  _host_tools_pidfile_check "${_d}" || return 1
  if _pid="$(_host_tools_gatekeeper_pid "$1" "${_d}")" && _host_tools_pid_is_gatekeeper "${_pid}" "${_d}"; then
    kill -TERM "${_pid}" 2>/dev/null || true
    _i=0
    while [[ "${_i}" -lt 100 ]] && _host_tools_pid_is_gatekeeper "${_pid}" "${_d}"; do
      sleep 0.1
      _i=$((_i + 1))
    done
    if _host_tools_pid_is_gatekeeper "${_pid}" "${_d}"; then
      kill -KILL "${_pid}" 2>/dev/null || true
      sleep 0.2
    fi
  fi
  rm -f "${_d}/host-tool.sock" "${_d}/gatekeeper.pid"
  return 0
}

# _host_tools_gatekeeper_start_unlocked CAGE JSON STATE_DIR -- the start, lock
# already held by the caller. A live gatekeeper is left alone (return 0). On
# failure: one Error: line naming the log, non-zero, nothing left running.
_host_tools_gatekeeper_start_unlocked() {
  local _cage="$1" _json="$2" _d="$3"
  local _py _sock _pidf _log _gk _i _pid _lpid _fd
  _sock="${_d}/host-tool.sock"; _pidf="${_d}/gatekeeper.pid"; _log="${_d}/gatekeeper.log"
  _gk="${SCRIPT_DIR}/cli/lib/host-tool-gatekeeper.py"
  if ! _py="$(_rc_python3)"; then
    echo "Error: python3 not found; the host-tool gatekeeper for cage ${_cage} was not started." >&2
    return 1
  fi
  _host_tools_pidfile_check "${_d}" || return 1
  if _host_tools_gatekeeper_alive "${_cage}" "${_d}"; then
    return 0
  fi
  # A socket left behind by a dead gatekeeper: rc is the one owner of this
  # unlink (the gatekeeper refuses to start over an existing path).
  if [[ -e "${_sock}" || -L "${_sock}" ]]; then
    if _host_tools_gatekeeper_pid "${_cage}" "${_d}" >/dev/null || ! _host_tools_sock_probe "${_py}" "${_sock}"; then
      rm -f "${_sock}" "${_pidf}"
    else
      echo "Error: ${_sock} is accepting connections but no live gatekeeper pid file of this cage names its owner; not starting one for cage ${_cage}." >&2
      return 1
    fi
  fi
  rm -f "${_pidf}"

  if ! (umask 077; printf '%s\n' "${_json}" > "${_d}/tools.json"); then
    echo "Error: cannot write ${_d}/tools.json; the host-tool gatekeeper for cage ${_cage} was not started." >&2
    return 1
  fi

  # Every inherited descriptor from 3 up is closed in the child, so neither
  # the lock (9) nor anything the caller left open reaches the gatekeeper.
  # shellcheck disable=SC2094  # the log path is an argument (the gatekeeper appends to it) and our stdout target; nothing here reads it
  (
    for _fd in $(seq 3 255); do eval "exec ${_fd}>&-"; done
    exec env -i PATH=/usr/bin:/bin HOME="${_d}" LANG="${LANG:-C.UTF-8}" \
      "${_py}" -I "${_gk}" --socket "${_sock}" --decl "${_d}/tools.json" \
      --log "${_log}" --pid "${_pidf}" --cwd "${_d}"
  ) </dev/null >>"${_log}" 2>&1 &
  _lpid=$!

  _i=0
  while [[ "${_i}" -lt 50 ]]; do
    if _pid="$(_host_tools_gatekeeper_pid "${_cage}" "${_d}")" && kill -0 "${_pid}" 2>/dev/null \
        && _host_tools_sock_probe "${_py}" "${_sock}"; then
      return 0
    fi
    kill -0 "${_lpid}" 2>/dev/null || break
    sleep 0.1
    _i=$((_i + 1))
  done
  # Not ready: TERM, up to 2 s, then KILL, and take back what it wrote.
  kill -TERM "${_lpid}" 2>/dev/null || true
  _i=0
  while [[ "${_i}" -lt 20 ]] && kill -0 "${_lpid}" 2>/dev/null; do
    sleep 0.1
    _i=$((_i + 1))
  done
  kill -0 "${_lpid}" 2>/dev/null && kill -KILL "${_lpid}" 2>/dev/null
  rm -f "${_pidf}" "${_sock}"
  echo "Error: the host-tool gatekeeper for cage ${_cage} did not become ready within 5 s; see ${_log}." >&2
  return 1
}

# _host_tools_gatekeeper_start CAGE NORMALIZED_JSON [STATE_DIR] -- start a
# gatekeeper serving NORMALIZED_JSON. The lock is held through launch and
# readiness (pid file written and the socket accepting), never longer.
_host_tools_gatekeeper_start() {
  local _d="${3:-$(_rc_state_dir "$1")}" _rc=0
  _d="${_d%/}"
  _host_tools_dir_ok "$1" "${_d}" || return 1
  _host_tools_lock_take "${_d}" || return 1
  _host_tools_gatekeeper_start_unlocked "$1" "$2" "${_d}" || _rc=$?
  _host_tools_lock_release "${_d}"
  return "${_rc}"
}

# _host_tools_gatekeeper_stop CAGE [STATE_DIR] -- stop the cage's gatekeeper
# under the lock. A directory that does not exist is nothing to stop (0).
# Non-zero, one Error: line, nothing removed, when the directory fails
# _host_tools_dir_ok or the pid file cannot be read.
_host_tools_gatekeeper_stop() {
  local _d="${2:-$(_rc_state_dir "$1")}" _rc=0
  _d="${_d%/}"
  [[ -e "${_d}" || -L "${_d}" ]] || return 0
  _host_tools_dir_ok "$1" "${_d}" || return 1
  _host_tools_lock_take "${_d}" || return 1
  _host_tools_gatekeeper_stop_unlocked "$1" "${_d}" || _rc=$?
  _host_tools_lock_release "${_d}"
  return "${_rc}"
}

# _host_tools_gatekeeper_restart CAGE NORMALIZED_JSON STATE_DIR -- stop any
# gatekeeper and start a fresh one as ONE section under the lock, so two
# rc up serialize. Creates the directory first (0700).
_host_tools_gatekeeper_restart() {
  local _d="${3%/}" _rc=0
  _host_tools_state_dir_create "$1" "${_d}" || return 1
  _host_tools_lock_take "${_d}" || return 1
  _host_tools_gatekeeper_stop_unlocked "$1" "${_d}" \
    && _host_tools_gatekeeper_start_unlocked "$1" "$2" "${_d}" || _rc=$?
  _host_tools_lock_release "${_d}"
  return "${_rc}"
}

# _host_tools_state_dir_remove CAGE STATE_DIR -- remove a cage's whole state
# directory after its gatekeeper is stopped. Returns 1 with one Error: line,
# removing nothing, for a path that fails _host_tools_dir_ok; 0 when removed
# or already absent.
_host_tools_state_dir_remove() {
  local _d="${2%/}"
  [[ -e "${_d}" || -L "${_d}" ]] || return 0
  _host_tools_dir_ok "$1" "${_d}" || return 1
  if [[ ! -d "${_d}" ]]; then
    echo "Error: ${_d} is not a directory; not removing it." >&2
    return 1
  fi
  rm -rf "${_d}"
}
