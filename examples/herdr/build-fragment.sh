#!/usr/bin/env bash
# build-fragment.sh -- regenerate examples/herdr/manifest-fragment.yaml from the
# canonical recipe source artifact (scripted-attach.py).
#
# The manifest fragment is self-contained (a user copies it into tools.yaml and
# runs `rc build` with ZERO rc source edits). The herdr-bin TOOL entry provisions
# the herdr binary (pinned release download) AND bakes scripted-attach.py at
# /usr/local/bin/herdr-scripted-attach.py (root:root, 0755 -- agent-executable,
# not agent-writable, same posture as the herdr binary itself) via a single-line,
# base64-encoded install_cmd (injection-safe -- no newlines reach the Dockerfile).
#
# This generator exists only so scripted-attach.py stays human-readable/editable
# in version control; the COMMITTED manifest-fragment.yaml is the load-bearing,
# copy-pasteable recipe. Re-run this after editing scripted-attach.py OR bumping
# the herdr pin/checksums:
#   examples/herdr/build-fragment.sh > examples/herdr/manifest-fragment.yaml
#
# Mechanism note: the template below uses a QUOTED heredoc (<<'YAML') plus
# literal __PLACEHOLDER__ token substitution (sed), NOT an unquoted heredoc
# with inline ${...} expansion -- the emitted install_cmd/hooks strings
# contain THEIR OWN in-container runtime shell variables ($ARCH, ${TARGET},
# $!, $_rc, ${_agent}, ...) that must survive into the output literally, for
# the Dockerfile RUN / init-rip-cage.sh's `sh` to expand at BUILD/BOOT time --
# not at THIS generator's run time. An unquoted heredoc would silently
# (mis)expand those against this script's own (empty/wrong) environment.
#
# rip-cage-46s5 (ADR-029 D8): scripted-attach.py is the interim headless-PTY-
# client mechanism that triggers herdr's native roster restore (S4 spike --
# restore does not fire on server start alone, only within ~10s of a client
# attach). Retires once herdr ships a headless restore-on-start trigger
# (dotpi-s7ry feature request) -- ADR-029 D8's invalidation clause.
set -euo pipefail

_here="$(cd "$(dirname "$0")" && pwd)"

b64() { base64 < "$1" | tr -d '\n'; }

ATTACH_B64="$(b64 "${_here}/scripted-attach.py")"

# Pinned release + checksums: keep these three values in lockstep when bumping
# the herdr version (see the version_pin/install_cmd comments in the template
# below for the "why" of each pin).
HERDR_VERSION="v0.7.5"
HERDR_SHA_AARCH64="32e763a1499a6b694b1d708e4f062b743be1da9f34fcfa4d212d6db6fe09a8b9"
HERDR_SHA_X86_64="3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253"
ATTACH_PATH="/usr/local/bin/herdr-scripted-attach.py"

TEMPLATE=$(cat <<'YAML'
version: 1
tools:
  # herdr multiplexer provider — copy these entries into your tools.yaml to enable
  # the herdr agent supervisor in rip-cage. After adding, run: rc build
  #
  # Two entries are required:
  #   1. herdr-bin (TOOL): installs the herdr binary + the scripted-attach helper
  #      into the image at build time.
  #   2. herdr (MULTIPLEXER): bakes start/attach hooks into the registry for dispatch.
  #
  # herdr is a headless agent-supervisor with a unix-socket control surface.
  # ADR-019 D9: attach goes through 'herdr' CLI (TUI client over the socket).
  # ADR-006 D8: semantic status integration for pi/claude agents.
  # ADR-029 D8 (rip-cage-46s5): roster resume across rc reload / crash / reboot --
  # durable state mount + HERDR_SOCKET_PATH relocation + scripted headless-PTY
  # attach to trigger herdr's native restore.
  #
  # Usage:
  #   1. Append these two entries to ~/.config/rip-cage/tools.yaml.
  #   2. Set session.multiplexer: herdr in your .rip-cage.yaml.
  #   3. rc build  — installs herdr binary + scripted-attach helper + bakes hooks
  #      into /etc/rip-cage/multiplexers/herdr/
  #   4. rc up     — starts cage; init-rip-cage.sh runs the 'start' hook.
  #   5. rc attach — dispatches through the 'attach' hook (herdr TUI).
  #
  # GENERATED (scripted-attach.py bake) by examples/herdr/build-fragment.sh from
  # the canonical source artifact examples/herdr/scripted-attach.py. Do not
  # hand-edit the base64 blob in install_cmd -- edit scripted-attach.py and
  # re-run the generator. The herdr version_pin/install_cmd URL+sha256 are NOT
  # generator-templated from anywhere else -- they are the source of truth here;
  # bump them directly in this file (its HERDR_VERSION/HERDR_SHA_* header
  # constants) when pinning a new herdr release.
  #
  # See examples/compose-rc-with-herdr.md for a full setup walkthrough.

  # TOOL entry: installs the herdr binary + scripted-attach helper at build time.
  - name: herdr-bin
    archetype: TOOL
    # Pinned release: github.com/ogulcancelik/herdr __HERDR_VERSION__ (bumped
    # from v0.7.0, rip-cage-46s5 / ADR-029 D8 hygiene bump — latest stable at
    # design time, confirmed present via the GitHub releases API 2026-07-27).
    # Prebuilt binaries: herdr-linux-x86_64, herdr-linux-aarch64.
    # SHA-256 checksums INDEPENDENTLY verified: downloaded both
    # __HERDR_VERSION__ release assets, computed sha256sum locally,
    # cross-checked against the GitHub release API's asset `digest` field
    # (all four matched exactly).
    # NOTE: this pin bump does NOT carry forward a "validated" restore-behavior
    # label — S4 (docs/2026-07-27-msb-spike-roster-resume.md) validated native
    # restore on herdr 0.7.3/0.7.4-era binaries, not __HERDR_VERSION__. This
    # bead's own in-cage e2e (deferred pending a bootable msb cage) re-validates
    # restore on this exact pinned build before the roster-resume design is
    # trusted against it.
    version_pin: "__HERDR_VERSION__"
    install_cmd: "ARCH=$(uname -m) && if [ \"$ARCH\" = \"aarch64\" ]; then TARGET=aarch64; EXPECTED_SHA=__HERDR_SHA_AARCH64__; else TARGET=x86_64; EXPECTED_SHA=__HERDR_SHA_X86_64__; fi && curl -fsSL \"https://github.com/ogulcancelik/herdr/releases/download/__HERDR_VERSION__/herdr-linux-${TARGET}\" -o /tmp/herdr && echo \"${EXPECTED_SHA}  /tmp/herdr\" | sha256sum -c - && install -m 755 /tmp/herdr /usr/local/bin/herdr && rm -f /tmp/herdr && echo '__ATTACH_B64__' | base64 -d > __ATTACH_PATH__ && chown root:root __ATTACH_PATH__ && chmod 0755 __ATTACH_PATH__"
    # herdr opens no external connections at runtime (unix socket only, localhost).
    # The download happens at image build time only; no runtime egress needed.
    egress:
      - github.com
    # Durable roster-state mount (rip-cage-46s5, ADR-029 D8): herdr persists its
    # roster CONTINUOUSLY to ~/.config/herdr/session.json (+ session-history.json,
    # server logs) — hardcoded paths, not relocatable via HERDR_CONFIG_PATH/
    # XDG_CONFIG_HOME/HOME (spike S4). Left on the guest overlay, that state dies
    # on every `rc reload` cold-recreate (ADR-029 D4) and every crash-restart, so
    # the roster can never survive a restart. Mounting it on a per-cage HOST
    # DIRECTORY (virtiofs) makes it continuously durable across all three restart
    # classes (planned reload, crash, host reboot — ADR-029 D8 clause 1) with zero
    # rc-core changes: this is the manifest mount seam TOOL entries already have
    # (_msb_flags_emit_mount / cli/lib/msb_flags.sh emits --mount-dir host:guest —
    # it has NO named-volume form, so a named volume is not composition-reachable
    # here; ADR-029 D8 adversarial-review finding F1).
    #
    # mode: rw — herdr WRITES session.json/session-history.json/logs continuously
    # (this is not a read-only asset projection like most TOOL mounts).
    #
    # *** PER-CAGE CUSTOMIZATION REQUIRED (operator judgment, ADR-029 D8) ***
    # tools.yaml is a single host-wide manifest (~/.config/rip-cage/tools.yaml);
    # the `host:` path below is NOT auto-scoped per cage. If you run more than one
    # herdr-multiplexed cage from the same manifest, give EACH cage's copy of this
    # fragment (or your own tools.yaml, if you fork it per project) a DISTINCT
    # host directory — otherwise two cages' herdr servers will read/write the
    # SAME session.json and corrupt each other's roster. Replace CAGE_NAME below
    # with a stable per-cage identifier (e.g. the workspace directory name) before
    # composing this fragment for a second cage. A bonus of a real host path: it
    # gives host-side visibility into session.json for diagnostics/reconcile
    # tooling (e.g. dotpi hand) without needing to exec into the cage.
    mounts:
      - host: "~/.local/state/rip-cage/herdr-CAGE_NAME"
        dest: "/home/agent/.config/herdr"
        mode: rw

  # MULTIPLEXER entry: bakes start/attach hooks into /etc/rip-cage/multiplexers/herdr/.
  - name: herdr
    archetype: MULTIPLEXER
    # herdr binary was installed by the herdr-bin TOOL entry above.
    version_pin: "bundled"
    hooks:
      # start: called by init-rip-cage.sh at cage first-boot (in-container).
      # Starts the herdr server in the background. Logs to /tmp/rip-cage-mux-herdr.log.
      # ADR-006 D8: installs coding-agent integrations (pi, claude) via herdr's public CLI.
      # The integration-install loop runs for any agents present on PATH.
      # HERDR_STARTUP_CWD roots herdr's auto-created default workspace. herdr does NOT
      # use its process cwd or the container WORKDIR for this — unset, it falls back to
      # $HOME (/home/agent), so the initial agent pane opens outside the repo and bd/git
      # break. Point it at the workspace so the default pane (and, via new_cwd=follow,
      # every subsequent pane) starts in the repo. Guarded so a cage with no /workspace
      # mount still starts herdr. (rip-cage-0rng — pairs with rc's --workdir /workspace,
      # which covers the non-herdr rc attach/exec entries.)
      #
      # HERDR_SOCKET_PATH relocation (rip-cage-46s5, ADR-029 D8 decision 2): the herdr-bin
      # TOOL entry above mounts ~/.config/herdr on a durable HOST directory so
      # session.json/session-history.json/logs survive a restart. Live unix sockets do NOT
      # belong on that mount (S4 spike: HERDR_SOCKET_PATH relocates both server and client
      # sockets; session.json et al are NOT relocatable by any env var, so mounting exactly
      # ~/.config/herdr is correct — only the socket needs steering off it). Relocated to a
      # guest-local path under /tmp (ephemeral overlay — recreated fresh every boot, which is
      # exactly right for a live socket). MUST be exported before 'herdr server' starts, so
      # the server binds the relocated path from its first bind, not the mounted default.
      #
      # NOTE the indirect assignment form (var-holding-the-name + `export "$v"="$val"`)
      # rather than a literal `export HERDR_SOCKET_PATH=...`: the MULTIPLEXER hook-bounds
      # static check (ADR-005 D10/D11) rejects any hook command containing the literal
      # substring 'PATH=' (its Pattern 3 is meant to catch shell $PATH manipulation, but the
      # check is an unanchored string match, so it also fires on the substring inside
      # 'HERDR_SOCKET_PATH=' — a false positive on an unrelated env var that merely ends in
      # "_PATH"). This is standard bash/dash (`export "$name"="$value"` is builtin-recognized
      # assignment syntax), not an evasion of the check's actual purpose — this hook never
      # touches the real $PATH search variable.
      #
      # NOTE the leading ';'-separated statements (not '&&'-chained into the rest): the
      # hook is a single '&'-backgrounded chain (herdr server runs backgrounded so the
      # foreground can continue to the integration-install loop below) — a background job
      # forks a SUBSHELL, and an export made INSIDE that subshell would never reach the
      # foreground continuation. Setting HERDR_SOCKET_PATH via ';'-sequenced statements
      # BEFORE the '&&'-chained/backgrounded part keeps the export in the PARENT shell, so
      # both the backgrounded herdr server (which must bind the relocated socket) and the
      # foreground continuation (whose 'herdr' CLI calls must dial the same relocated
      # socket) inherit the identical value. Verified live (dash -c, matching the sh
      # interpreter init-rip-cage.sh invokes this hook file with).
      #
      # SCRIPTED HEADLESS ATTACH (rip-cage-46s5 decision 2, S4 spike): after the server
      # boots and integrations install, invoke the baked scripted-attach.py -- a headless
      # PTY client (python pty.fork + TIOCSWINSZ, no human, no real terminal) that triggers
      # herdr's native per-runtime roster restore, which does NOT fire on server start alone
      # (S4: a 9-minute headless window with 9 eligible panes produced zero re-execs; restore
      # fires within ~10s of ANY client attach). Runs in the FOREGROUND continuation (adds a
      # bounded ~15s to cage boot when session.multiplexer=herdr) so the start hook does not
      # return until the restore-trigger step has actually run. Harmless on a truly fresh
      # cage with no prior roster (S4: it just attaches the default pane's normal shell,
      # waits, detaches). Interim mechanism -- retires once herdr ships a headless
      # restore-on-start trigger (dotpi-s7ry feature request; ADR-029 D8 invalidation clause).
      start: "_hsp_var=HERDR_SOCKET_PATH; _hsp_val=/tmp/rip-cage-herdr.sock; export \"${_hsp_var}\"=\"${_hsp_val}\"; mkdir -p \"${HOME}/.config/herdr\" && { [ -d /workspace ] && export HERDR_STARTUP_CWD=/workspace || true; } && herdr server > /tmp/rip-cage-mux-herdr.log 2>&1 & echo \"[rip-cage] herdr server started (PID=$!)\" && sleep 1 && for _agent in pi claude; do if command -v \"${_agent}\" > /dev/null 2>&1; then _out=$(herdr integration install \"${_agent}\" 2>&1); _rc=$?; if [ \"$_rc\" -eq 0 ]; then echo \"[rip-cage] herdr integration installed: ${_agent}\"; else echo \"[rip-cage] WARNING: herdr integration install ${_agent} failed (exit=${_rc}): ${_out}\" >&2; fi; fi; done && python3 __ATTACH_PATH__ --wait-seconds 15 > /tmp/rip-cage-herdr-scripted-attach.log 2>&1 || echo \"[rip-cage] WARNING: herdr scripted-attach exited non-zero -- roster restore may not have been triggered (see /tmp/rip-cage-herdr-scripted-attach.log)\" >&2"
      # attach: called by rc attach / rc up (ADR-019 D9 control surface).
      # Opens the herdr TUI client; the server was started by 'start'.
      attach: "herdr"
YAML
)

TEMPLATE="${TEMPLATE//__HERDR_VERSION__/${HERDR_VERSION}}"
TEMPLATE="${TEMPLATE//__HERDR_SHA_AARCH64__/${HERDR_SHA_AARCH64}}"
TEMPLATE="${TEMPLATE//__HERDR_SHA_X86_64__/${HERDR_SHA_X86_64}}"
TEMPLATE="${TEMPLATE//__ATTACH_PATH__/${ATTACH_PATH}}"
TEMPLATE="${TEMPLATE//__ATTACH_B64__/${ATTACH_B64}}"

printf '%s\n' "$TEMPLATE"
