#!/usr/bin/env bash
# floor-probe.sh — the fail-closed floor probe on the BUILT image.
#
# Baked at /usr/local/lib/rip-cage/floor-probe.sh, root:root 0555. Run by
# `init-rip-cage.sh` FIRST at every boot, and by `rc test <cage>`. Any FAIL and
# init refuses to start the agent shell. There is no escape hatch: no env var,
# no flag, no skip file (ADR-031 D5(b), FIRM).
#
# WHY A PROBE AND NOT A VALIDATOR. It replaces the retired declaration
# validator (ADR-005 D11). A validator reads a description of the image and can
# be lied to by that description — it cannot see a `USER root` the extension
# Dockerfile ends with. This reads the artifact. The threat it targets is
# ADR-024's: a prompt-injected agent (or a careless one) composing an extension
# Dockerfile that quietly removes a floor property. Image CONTENT is the only
# thing an extension Dockerfile can change; the mount side and the egress side
# are msb config `rc up` emits before the cage exists (ADR-031 D5(a)/(d)).
#
# WHERE IT RUNS IN INIT, AND WHY THAT IS SAFE. It runs BEFORE init section 1,
# the block that chowns the bind-mounted dirs. That is deliberate and it costs
# nothing, because NO CHECK BELOW STATS ANYTHING UNDER THE MOUNTED HOME. The
# settings-template check reads the image's baked /etc/rip-cage/settings.json,
# not the agent's ~/.claude/settings.json, precisely so the probe never has to
# tolerate pre-chown state. Keep it that way: a check that needs the mounted
# home belongs in test-safety-stack.sh, not here.
#
# KEEPING THIS IN STEP WITH THE IMAGE (ADR-031 D5(b)'s own invalidation cue).
# Every check names the cage/Dockerfile line it guards. Add a floor property to
# the Dockerfile, add its check here in the same change — a floor property the
# probe does not know about is a containment gap that survives a green
# `rc test`, which is exactly the drift this file exists to make visible.
#
# THE CHECK LIST — property, why it is floor, and what it guards:
#
#   runtime-user             The cage runs as the image's floor user, not root
#                            and not some other user. cage/Dockerfile:127-128
#                            (useradd agent, uid 1000) + :197 (USER agent).
#                            A `USER root` extension boots SILENTLY today
#                            (measured, rip-cage-ely4.16 Q2).
#   agent-home               $HOME is the floor user's passwd home. Same
#                            Dockerfile lines, plus :202/:207 which pre-create
#                            the mount targets under it. This is the check that
#                            names the REAL damage of a changed USER: every host
#                            mount stays stranded at /home/agent while the shell
#                            reads an empty config from somewhere else. It
#                            catches `USER <anyone>`, not only `USER root`.
#   sudo-scope               The agent's effective sudo grant is exactly the one
#                            baked at cage/Dockerfile:129-130 — no wildcard, and
#                            nothing a second /etc/sudoers.d file added.
#   guard-file <path>        Each root-owned floor artifact is root-owned AND
#                            carries no group/other write bit. Owner alone is
#                            not enough: a chmod o+w on a root-owned file leaves
#                            it agent-writable and passed the old owner-only
#                            check (rip-cage-ely4.15). Paths and their lines are
#                            listed at _rc_floor_guard_paths below.
#   bd-wrapper               /usr/local/bin/bd is a script and /usr/local/bin/bd-real
#                            exists executable — the indirection ADR-007 D2's
#                            dolt-server block depends on. cage/Dockerfile:83-85.
#   path-resolution <name>   The floor's wrappers RESOLVE to the floor's own
#                            files in the INTERACTIVE shell's PATH. Presence is
#                            not enough and the exec PATH is not the right PATH:
#                            an extension's ENV PATH prepend survives into the
#                            interactive zsh and shadows /usr/local/bin, and
#                            ~/.local/bin (which cage/agent/zshrc prepends, and
#                            which does not exist in the base image) outranks
#                            everything (measured, rip-cage-ely4.16 Q3).
#                            cage/Dockerfile:84 (bd) and :115-124 (the generic
#                            launch wrapper). The tool names come from the boot
#                            descriptor, so this file names no tool (ADR-005 D12).
#   git-hooks-deny           The baked settings template still denies writes to
#                            .git/hooks. cage/Dockerfile:162. Init copies this
#                            template into the agent's home on EVERY boot and
#                            every resume, so an agent-editable template is a
#                            live vector, not a build-time one.
#   ssh-host-key-pin         The image-baked system-path github.com host key is
#                            still pinned. cage/Dockerfile:155-158. ADR-029 D3
#                            retired the ssh CLUSTER — agent forwarding, the
#                            host+key allowlist, the per-cage filtered
#                            known_hosts mount — and git now authenticates over
#                            HTTPS with an msb --secret token. What survives is
#                            this two-file static posture, and it is floor for a
#                            reason that has nothing to do with the retired
#                            transport: `ssh` is still installed, so a stray
#                            `git@github.com:` remote must fail FAST and
#                            deterministically rather than sit on a host-key
#                            prompt. That is the autonomy property (a cage the
#                            human walked away from must not block on a TTY),
#                            and StrictHostKeyChecking only delivers it against
#                            a pinned key. See the dated note on ADR-029 D3.
#   python3                  python3 is present — the skill-server.py MCP shim
#                            is dead without it. cage/Dockerfile:32.
#                            (Lifted out of init section 5.)
#   mise-trusted-path        MISE_TRUSTED_CONFIG_PATHS is still /workspace.
#                            cage/Dockerfile:23. Widening it lets mise
#                            auto-trust config outside the workspace.
#
# DELIBERATELY NOT CHECKED, so a later reader does not "fix" the omission:
#
#   /etc/rip-cage/cage-env   Agent-writable BY DESIGN (cage/Dockerfile:138-141)
#                            — the ADR-016 D2 preflight probe writes it without
#                            a sudoers entry. It is not a guard file.
#   ~/.claude/settings.json  The RUNTIME copy init lays down each boot. The
#                            probe checks the baked TEMPLATE instead (see
#                            git-hooks-deny) — a different artifact, not a
#                            duplicate. test-safety-stack.sh still checks the
#                            runtime copy, which is what catches a regression in
#                            init's copy step rather than in the image.
#   the pinned key's FINGERPRINT
#                            Floor is "a pin is present and unwritable". Which
#                            key github publishes is upstream's to rotate, so
#                            the fingerprint equality stays a regression test in
#                            test-safety-stack.sh. A probe that refused to boot
#                            on an upstream key rotation would be the
#                            mis-specified probe ADR-031 D5(b) warns about.
#   read-only-ness of any mount
#                            Mount modes are msb config, not image content —
#                            ADR-031 D5(d)'s half, not D5(b)'s. And a mount
#                            table cannot prove it: `mount -o remount,rw` on a
#                            :ro mount returns 0 and flips the guest table while
#                            the write still fails EROFS (measured, msb 0.6.18,
#                            rip-cage-ely4.16 Q1). The only honest proof is an
#                            attempted write that fails, which is what
#                            test-safety-stack.sh already does for .git/hooks.
#
# EXIT: 0 when every check passes. Otherwise one `FAIL: floor: <property>` line
# per failure and exit 1 — the shape init and the tests both read.

set -uo pipefail

_RC_FLOOR_PASS=0
_RC_FLOOR_FAIL=0
_RC_FLOOR_TOTAL=0
_RC_FLOOR_FAILED_PROPS=()

# check <property> <pass|fail> [detail] — same line shape as
# tests/test-safety-stack.sh's check(), because `rc test` parses PASS/FAIL
# lines out of every in-cage suite with one regex (cli/test.sh).
check() {
  local _prop="$1" _result="$2" _detail="${3:-}"
  _RC_FLOOR_TOTAL=$((_RC_FLOOR_TOTAL + 1))
  if [ "$_result" = "pass" ]; then
    echo "PASS  [${_RC_FLOOR_TOTAL}] floor: ${_prop}${_detail:+ — $_detail}"
    _RC_FLOOR_PASS=$((_RC_FLOOR_PASS + 1))
  else
    echo "FAIL  [${_RC_FLOOR_TOTAL}] floor: ${_prop}${_detail:+ — $_detail}"
    _RC_FLOOR_FAIL=$((_RC_FLOOR_FAIL + 1))
    _RC_FLOOR_FAILED_PROPS+=("${_prop}${_detail:+ — $_detail}")
  fi
}

echo "=== Rip Cage floor probe (ADR-031 D5b) ==="

# ---------------------------------------------------------------------------
# runtime-user + agent-home (cage/Dockerfile:127-128, :197, :202, :207)
# ---------------------------------------------------------------------------
# The floor user is read out of /etc/passwd rather than assumed, so the two
# checks below compare the image against itself: who is running, versus who the
# image was built to run as.
_rc_floor_user=$(id -un 2>/dev/null || echo "")
_rc_floor_uid=$(id -u 2>/dev/null || echo "")
_rc_floor_passwd_home=$(getent passwd agent 2>/dev/null | cut -d: -f6)

if [ "$_rc_floor_uid" = "0" ]; then
  check "runtime-user" "fail" \
    "running as uid 0 (${_rc_floor_user:-root}) — the image ends on a root USER, so the agent shell would be root"
elif [ "$_rc_floor_user" != "agent" ]; then
  check "runtime-user" "fail" \
    "running as '${_rc_floor_user}' (uid ${_rc_floor_uid}) — the image's floor user is 'agent'"
else
  check "runtime-user" "pass" "${_rc_floor_user} (uid ${_rc_floor_uid})"
fi

if [ -z "$_rc_floor_passwd_home" ]; then
  check "agent-home" "fail" "no 'agent' entry in /etc/passwd — the image's floor user was removed"
elif [ "${HOME:-}" != "$_rc_floor_passwd_home" ]; then
  check "agent-home" "fail" \
    "HOME='${HOME:-<unset>}' but the floor user's home is '${_rc_floor_passwd_home}' — every host mount is laid at '${_rc_floor_passwd_home}' and is stranded there (credentials, projects, sessions, skills)"
else
  check "agent-home" "pass" "$HOME"
fi

# ---------------------------------------------------------------------------
# sudo-scope (cage/Dockerfile:129-130)
# ---------------------------------------------------------------------------
# The authority here is `sudo -n -l` — the grant that ACTUALLY applies, from
# every file under /etc/sudoers.d. A second drop-in an extension added shows up
# there and nowhere else, which is why this does not read the baked file: at
# 0440 root:root the agent cannot read it anyway (by design), and reading it
# would only tell us about one of the files that feed the grant.
#
# WHY THE EXPECTED LIST IS LITERAL HERE. It is the grant baked at
# cage/Dockerfile:129. This file is root-owned 0555, so the literal cannot be
# edited from inside the cage, and `tests/test-dockerfile-sudoers.sh` asserts
# host-side that this list and that Dockerfile line still say the same thing —
# so the two cannot drift apart without a red host suite. Change one, change
# both.
_rc_floor_sudo_expected='/usr/bin/apt-get
/usr/bin/chown -R agent:agent /home/agent/.local/share/mise
/usr/bin/chown agent:agent /home/agent/.claude
/usr/bin/chown agent:agent /home/agent/.claude-state
/usr/bin/chown agent:agent /home/agent/.pi/agent
/usr/bin/dpkg'
_rc_floor_sudoers=/etc/sudoers.d/agent
if [ ! -f "$_rc_floor_sudoers" ]; then
  check "sudo-scope" "fail" "${_rc_floor_sudoers} is missing — the agent's scoped grant is gone"
else
  _rc_floor_sudoers_owner=$(stat -c '%U:%G' "$_rc_floor_sudoers" 2>/dev/null || echo "?")
  _rc_floor_sudoers_mode=$(stat -c '%a' "$_rc_floor_sudoers" 2>/dev/null || echo "?")
  # `sudo -n -l` lists the grants that actually apply, from every sudoers file.
  # Commands are comma-separated on the NOPASSWD line; normalize to one per
  # line, drop sudo's backslash escaping of the `agent\:agent` colons, and trim.
  _rc_floor_sudo_effective=$(sudo -n -l 2>/dev/null \
    | sed -n 's/^[[:space:]]*(ALL)[[:space:]]*NOPASSWD:[[:space:]]*//p' \
    | tr ',' '\n' | sed 's/\\//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort)
  _rc_floor_sudo_baked=$(printf '%s\n' "$_rc_floor_sudo_expected" | sort)
  if [ "$_rc_floor_sudoers_owner" != "root:root" ]; then
    check "sudo-scope" "fail" "${_rc_floor_sudoers} is owned by ${_rc_floor_sudoers_owner} (expected root:root) — the agent can rewrite its own grant"
  elif [ "$_rc_floor_sudoers_mode" != "440" ]; then
    check "sudo-scope" "fail" "${_rc_floor_sudoers} mode is 0${_rc_floor_sudoers_mode} (expected 0440)"
  elif printf '%s\n' "$_rc_floor_sudo_effective" | grep -qx 'ALL'; then
    check "sudo-scope" "fail" "the agent's effective sudo grant includes the unrestricted command ALL — the scope is gone"
  elif [ -z "$_rc_floor_sudo_effective" ]; then
    check "sudo-scope" "fail" "sudo -n -l reported no NOPASSWD grant — cannot verify the scope is unwidened"
  elif [ "$_rc_floor_sudo_effective" != "$_rc_floor_sudo_baked" ]; then
    check "sudo-scope" "fail" \
      "the agent's effective sudo grant is not the floor's grant — something under /etc/sudoers.d changed it. effective: $(printf '%s' "$_rc_floor_sudo_effective" | tr '\n' '|')"
  else
    check "sudo-scope" "pass" "$(printf '%s' "$_rc_floor_sudo_baked" | grep -c .) scoped command(s), file root:root 0440"
  fi
fi

# ---------------------------------------------------------------------------
# guard-file <path> (owner AND mode bits — rip-cage-ely4.15)
# ---------------------------------------------------------------------------
# Every path here must be root-owned and carry NO group or other write bit. The
# mode half is the bug this closes: `chmod o+w` on a root-owned file leaves it
# agent-writable while the old owner-only check stayed green.
#
# Paths present in every cage (with the cage/Dockerfile line each guards):
#   /etc/rip-cage/release            :150-152  the unforgeable "inside a cage" marker
#   /etc/rip-cage/boot.json          :173-177  declares what STARTS inside the cage
#   /etc/rip-cage/settings.json      :162      the settings template init copies each boot
#   /usr/local/bin/bd                :84       the bd wrapper (see bd-wrapper below)
#   /usr/local/bin/bd-real           :83       the real binary the wrapper defers to
#   /usr/local/bin/init-rip-cage.sh  :178,:183 this probe's own caller
#   /usr/local/lib/rip-cage/floor-probe.sh     this probe itself
#
# Paths a composed recipe provisions — checked only when present, because a
# minimal cage has none of them and that is a valid cage, not a broken one.
# These are the paths init section 5b asserts ownership on (ADR-027 D1/D3);
# this loop is what adds the mode-bit half for them.
_rc_floor_guard_paths=(
  /etc/rip-cage/release
  /etc/rip-cage/boot.json
  /etc/rip-cage/settings.json
  /usr/local/bin/bd
  /usr/local/bin/bd-real
  /usr/local/bin/init-rip-cage.sh
  /usr/local/lib/rip-cage/floor-probe.sh
  /etc/ssh/ssh_known_hosts
  /etc/ssh/ssh_config.d/00-rip-cage.conf
)
_rc_floor_guard_optional=(
  /etc/rip-cage/pi
  /etc/rip-cage/pi/dcg-gate.ts
  /usr/local/lib/rip-cage/bin/dcg-guard
  /etc/claude-code
  /etc/claude-code/managed-settings.json
)

_rc_floor_check_guard() {
  local _path="$1" _required="$2"
  if [ ! -e "$_path" ]; then
    if [ "$_required" = "required" ]; then
      check "guard-file ${_path}" "fail" "missing from the image"
    fi
    return 0
  fi
  local _owner _mode
  _owner=$(stat -c '%U:%G' "$_path" 2>/dev/null || echo "?")
  _mode=$(stat -c '%a' "$_path" 2>/dev/null || echo "?")
  # Left-pad to four digits so the setuid/sticky column never shifts the bits
  # we read: %a prints 444 for a plain file and 4755 for a setuid one.
  while [ "${#_mode}" -lt 4 ]; do _mode="0${_mode}"; done
  local _group_w="${_mode:2:1}" _other_w="${_mode:3:1}"
  if [ "$_owner" != "root:root" ]; then
    check "guard-file ${_path}" "fail" "owned by ${_owner} (expected root:root) — the agent can replace it"
  elif [ $(( _group_w & 2 )) -ne 0 ] || [ $(( _other_w & 2 )) -ne 0 ]; then
    check "guard-file ${_path}" "fail" "mode ${_mode} is group/other-writable — root-owned but the agent can still write it"
  else
    check "guard-file ${_path}" "pass" "root:root ${_mode}"
  fi
}

for _rc_floor_p in "${_rc_floor_guard_paths[@]}"; do
  _rc_floor_check_guard "$_rc_floor_p" required
done
for _rc_floor_p in "${_rc_floor_guard_optional[@]}"; do
  _rc_floor_check_guard "$_rc_floor_p" optional
done

# ---------------------------------------------------------------------------
# bd-wrapper (cage/Dockerfile:83-85)
# ---------------------------------------------------------------------------
# The indirection itself, not the wrapper's policy: `rc test`'s
# test-safety-stack.sh still exercises what the wrapper BLOCKS. Ownership and
# mode of both files are covered by the guard-file loop above.
_rc_floor_bd_shebang=$(head -c 2 /usr/local/bin/bd 2>/dev/null || true)
if [ "$_rc_floor_bd_shebang" != "#!" ]; then
  check "bd-wrapper" "fail" "/usr/local/bin/bd is not a script (starts '${_rc_floor_bd_shebang}') — the wrapper was replaced by a binary"
elif [ ! -x /usr/local/bin/bd-real ]; then
  check "bd-wrapper" "fail" "/usr/local/bin/bd-real is missing or not executable — the wrapper has nothing to defer to"
else
  check "bd-wrapper" "pass" "/usr/local/bin/bd is a script, bd-real is executable"
fi

# ---------------------------------------------------------------------------
# path-resolution <name> (cage/Dockerfile:84, :115-124)
# ---------------------------------------------------------------------------
# Resolution happens in the INTERACTIVE shell, which is where the agent's
# commands actually run and whose PATH differs from this script's (the login
# zshrc prepends ~/.local/bin and ~/go/bin ahead of /usr/local/bin). A plain
# `command -v` here would miss exactly the shadow this check exists to catch.
_rc_floor_resolve() {
  local _name="$1"
  if [ -x /usr/bin/zsh ]; then
    /usr/bin/zsh -ic "command -v ${_name}" 2>/dev/null | tail -1
  else
    command -v "$_name" 2>/dev/null
  fi
}

_rc_floor_bd_resolved=$(_rc_floor_resolve bd)
if [ "$_rc_floor_bd_resolved" != "/usr/local/bin/bd" ]; then
  check "path-resolution bd" "fail" \
    "'bd' resolves to '${_rc_floor_bd_resolved:-nothing}' in the interactive shell, not /usr/local/bin/bd — the wrapper is shadowed"
else
  check "path-resolution bd" "pass" "/usr/local/bin/bd"
fi

# The agent-tool names come out of the boot descriptor, so this probe names no
# tool of its own (ADR-005 D12). The floor installs ONE generic launch wrapper
# and copies it to each tool's own name, so "resolves to the floor's wrapper"
# is a byte comparison against that one file — no need to know where npm put
# the binary, and no path an extension could match by planting a same-named
# file of its own.
_rc_floor_wrapper=/usr/local/lib/rip-cage/tool-launch-wrapper
_rc_floor_descriptor="${RC_BOOT_DESCRIPTOR:-/etc/rip-cage/boot.json}"
if [ -f "$_rc_floor_wrapper" ] && [ -f "$_rc_floor_descriptor" ]; then
  while IFS= read -r _rc_floor_tool; do
    [ -z "$_rc_floor_tool" ] && continue
    _rc_floor_tool_resolved=$(_rc_floor_resolve "$_rc_floor_tool")
    if [ -z "$_rc_floor_tool_resolved" ]; then
      # Declared but not installed is a composition choice, not a floor break:
      # a descriptor entry may name a tool an extension supplies later.
      continue
    fi
    if cmp -s "$_rc_floor_tool_resolved" "$_rc_floor_wrapper"; then
      check "path-resolution ${_rc_floor_tool}" "pass" "$_rc_floor_tool_resolved"
    else
      check "path-resolution ${_rc_floor_tool}" "fail" \
        "'${_rc_floor_tool}' resolves to '${_rc_floor_tool_resolved}', which is not the floor's launch wrapper — the wrapper is shadowed or replaced"
    fi
  done <<<"$(jq -r '(.tools // [])[] | .name // empty' "$_rc_floor_descriptor" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# git-hooks-deny (cage/Dockerfile:162)
# ---------------------------------------------------------------------------
_rc_floor_settings=/etc/rip-cage/settings.json
if jq -e '.permissions.deny[]? | select(startswith("Write(.git/hooks"))' "$_rc_floor_settings" >/dev/null 2>&1; then
  check "git-hooks-deny" "pass" "$_rc_floor_settings"
else
  check "git-hooks-deny" "fail" \
    "${_rc_floor_settings} has no .permissions.deny entry for Write(.git/hooks — init copies this template into the agent's home on every boot"
fi

# ---------------------------------------------------------------------------
# ssh-host-key-pin (cage/Dockerfile:155-158)
# ---------------------------------------------------------------------------
# Presence of a pin, not which key it is — see the "deliberately not checked"
# note on the fingerprint above. The two files' ownership and mode are covered
# by the guard-file loop.
if grep -q '^github\.com ssh-ed25519 ' /etc/ssh/ssh_known_hosts 2>/dev/null; then
  check "ssh-host-key-pin" "pass" "/etc/ssh/ssh_known_hosts pins github.com"
else
  check "ssh-host-key-pin" "fail" \
    "/etc/ssh/ssh_known_hosts has no github.com host-key line — with StrictHostKeyChecking on, a stray ssh remote fails on an unverifiable host instead of on a pinned one"
fi

# ---------------------------------------------------------------------------
# python3 (cage/Dockerfile:32) — lifted out of init section 5.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  check "python3" "pass" "$(command -v python3)"
else
  check "python3" "fail" "not installed — skill discovery (skill-server.py) cannot run"
fi

# ---------------------------------------------------------------------------
# mise-trusted-path (cage/Dockerfile:23)
# ---------------------------------------------------------------------------
if [ "${MISE_TRUSTED_CONFIG_PATHS:-}" = "/workspace" ]; then
  check "mise-trusted-path" "pass" "/workspace"
else
  check "mise-trusted-path" "fail" \
    "MISE_TRUSTED_CONFIG_PATHS='${MISE_TRUSTED_CONFIG_PATHS:-<unset>}' (expected /workspace) — mise would auto-trust config outside the workspace"
fi

# ---------------------------------------------------------------------------
echo "=== Floor: ${_RC_FLOOR_PASS} passed, ${_RC_FLOOR_FAIL} failed (of ${_RC_FLOOR_TOTAL}) ==="
if [ "$_RC_FLOOR_FAIL" -ne 0 ]; then
  echo ""
  for _rc_floor_prop in "${_RC_FLOOR_FAILED_PROPS[@]}"; do
    echo "FAIL: floor: ${_rc_floor_prop}"
  done
  echo ""
  echo "[rip-cage] The image does not meet the containment floor. Refusing to start the agent shell." >&2
  echo "[rip-cage] Fix the Dockerfile that built this image and rebuild; there is no way to skip this check (ADR-031 D5b)." >&2
  exit 1
fi
exit 0
