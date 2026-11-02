#!/usr/bin/env bash
set -uo pipefail

# tests/test-sha256-fallback.sh -- host-tier proof for rip-cage-vw7c: rc's
# SHA-256 hashing works whichever of shasum / sha256sum the host carries.
#
# Arch ships shasum inside perl at /usr/bin/core_perl, which is off the
# default PATH, so a bare `shasum -a 256` killed `rc up` with exit 127 right
# after "Creating container". macOS has shasum and no sha256sum; GNU coreutils
# has sha256sum on every Linux. rc hashes through one helper, _up_sha256.
#
#   H1  PATH without shasum, with sha256sum  -> correct digest (file + stdin)
#   H2  PATH with shasum, without sha256sum  -> correct digest (file + stdin)
#   H3  PATH with neither                    -> non-zero, error names both
#   H4  no shasum/sha256sum call in rc or cli/ outside the helper
#
# Each PATH is a symlink farm of every executable on the caller's PATH minus
# the masked tool, so the case holds on Linux and macOS alike.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
RC="${REPO_ROOT}/rc"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

T=$(mktemp -d /tmp/rc-sha256-XXXXXX) || { echo "FAIL: cannot create a temp dir"; exit 1; }
T=$(cd "$T" && pwd -P) || { echo "FAIL: cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT

# SHA-256 of the three bytes "abc" (FIPS 180-2 test vector).
WANT="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
printf 'abc' > "${T}/abc"

# _farm NAME MASKED... -- a PATH dir holding every executable on PATH except MASKED.
_farm() {
  local _dir="${T}/$1" _d _m; shift
  mkdir -p "$_dir"
  local IFS=:
  for _d in $PATH; do
    [[ -d "$_d" ]] || continue
    ln -s "$_d"/* "$_dir"/ 2>/dev/null || true
  done
  for _m in "$@"; do rm -f "${_dir}/${_m}"; done
  printf '%s' "$_dir"
}

# _hash FARM MODE -- run _up_sha256 under PATH=FARM; MODE is file or stdin.
_hash() {
  local _farm_dir="$1" _mode="$2"
  if [[ "$_mode" == "file" ]]; then
    PATH="$_farm_dir" "${_farm_dir}/bash" -c "source '${RC}' >/dev/null 2>&1; _up_sha256 '${T}/abc'" 2>"${T}/err"
  else
    PATH="$_farm_dir" "${_farm_dir}/bash" -c "source '${RC}' >/dev/null 2>&1; printf abc | _up_sha256" 2>"${T}/err"
  fi
}

_expect_digest() {
  local _label="$1" _farm_dir="$2" _mode _got
  for _mode in file stdin; do
    _got=$(_hash "$_farm_dir" "$_mode")
    if [[ "$_got" == "$WANT" ]]; then
      pass "${_label} ${_mode}: digest correct"
    else
      fail "${_label} ${_mode}: got '${_got}' (stderr: $(head -2 "${T}/err"))"
    fi
  done
}

echo "=== H1: no shasum, sha256sum present ==="
F1=$(_farm no-shasum shasum)
if [[ -x "${F1}/sha256sum" ]]; then
  _expect_digest H1 "$F1"
else
  echo "SKIP: H1 -- host has no sha256sum"
fi

echo "=== H2: shasum present, no sha256sum ==="
F2=$(_farm no-sha256sum sha256sum)
if [[ -x "${F2}/shasum" ]]; then
  _expect_digest H2 "$F2"
else
  echo "SKIP: H2 -- host has no shasum on PATH"
fi

echo "=== H3: neither tool ==="
F3=$(_farm neither shasum sha256sum)
_out=$(_hash "$F3" file); _rc=$?
if [[ $_rc -ne 0 && -z "$_out" ]]; then
  pass "H3 exits non-zero (${_rc}) with no digest"
else
  fail "H3 exit ${_rc}, stdout '${_out}' -- want non-zero and empty"
fi
if grep -q 'shasum' "${T}/err" && grep -q 'sha256sum' "${T}/err"; then
  pass "H3 error names both shasum and sha256sum"
else
  fail "H3 error does not name both tools: $(cat "${T}/err")"
fi

echo "=== H4: every hash call routes through _up_sha256 ==="
# Code lines (comments stripped) naming either tool, minus the helper's own body
# (cli/up.sh, from its definition line to the next column-0 closing brace).
UP="${REPO_ROOT}/cli/up.sh"
_h_start=$(grep -n '^_up_sha256() {' "$UP" | cut -d: -f1)
_h_end=""
[[ -n "$_h_start" ]] && _h_end=$(tail -n +"$_h_start" "$UP" | grep -n '^}' | head -1 | cut -d: -f1)
[[ -n "$_h_end" ]] && _h_end=$((_h_start + _h_end - 1))
_calls=$(grep -rnE 'shasum|sha256sum' "$RC" "${REPO_ROOT}/cli" \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
  | while IFS= read -r _hit; do
      _f=${_hit%%:*}; _rest=${_hit#*:}; _n=${_rest%%:*}
      if [[ -n "$_h_end" && "$_f" -ef "$UP" && $_n -ge $_h_start && $_n -le $_h_end ]]; then continue; fi
      printf '%s\n' "$_hit"
    done)
if [[ -z "$_h_start" ]]; then
  fail "H4 helper _up_sha256 not defined in cli/up.sh"
fi
if [[ -z "$_calls" ]]; then
  pass "H4 no direct shasum/sha256sum call in rc or cli/"
else
  fail "H4 direct hash call(s) bypass _up_sha256: ${_calls}"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s)"
  exit 1
fi
echo "All checks passed."
