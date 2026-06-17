#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# init-mediator.sh — Root-phase mediator init inside the container.
# (rip-cage-ta1o.5.8 / ADR-026 D5)
#
# Called by cmd_up via `docker exec -u root <name> /usr/local/lib/rip-cage/init-mediator.sh`
# on BOTH the create path AND the resume path, AFTER _up_init_firewall (which
# installs the uid-exemption RETURN rule for the mediator uid) and BEFORE
# _up_init_container (init-rip-cage.sh).
#
# RC_MEDIATOR must be set in the container environment (threaded in by cmd_up
# via -e RC_MEDIATOR=<value> in docker run). If RC_MEDIATOR is absent/empty/none,
# this script exits 0 silently — no mediator is running.
#
# RIPCAGE_MEDIATOR_* env vars (the secret channel) are injected via the docker exec
# -e flags only into THIS root exec, NOT into the docker run env, so the agent
# (PID 1 sleep infinity) cannot read them from /proc/1/environ.
#
# Architecture (ADR-026 D5):
#   1. Reads RC_MEDIATOR → looks up /etc/rip-cage/mediators/<name>/{start,run_as_uid}
#   2. Fail-closed uid validation (ADR-001): empty / "0" / "root" → refuse loud
#   3. Idempotency: if a PID file exists and the process is alive, skip (no double-start)
#   4. Privilege drop: root → run_as_uid via `su -s /bin/sh <uid> -c 'nohup ... &'`
#      (mirrors init-firewall.sh:504 pattern; nohup ensures survival past exec return)
#   5. CA trust (optional): if the MEDIATOR registry has a ca_cert_path file pointing at
#      a generated CA, install it into /usr/local/share/ca-certificates/ + run
#      update-ca-certificates so agent curl can verify the TLS MITM cert.
#      The ca_cert_path field is set in the manifest and baked into the image registry.
#      This script waits briefly for the cert to appear (generated at first start).
#
# ADR-005 D12 FIRM: zero hardcoded mediator names in this file. Everything drives
# off RC_MEDIATOR + the baked registry files. The grep-floor check in the test suite
# and bead acceptance criteria MUST return 0 hits for specific tool names.
# ---------------------------------------------------------------------------

set -uo pipefail

# ---------------------------------------------------------------------------
# Quick exit when no mediator is configured.
# ---------------------------------------------------------------------------
_rc_med="${RC_MEDIATOR:-}"
if [[ -z "$_rc_med" || "$_rc_med" == "none" ]]; then
  echo "[rip-cage] init-mediator: RC_MEDIATOR absent/none — no mediator to start"
  exit 0
fi

# ---------------------------------------------------------------------------
# Registry lookup
# ---------------------------------------------------------------------------
_rc_med_registry_dir="/etc/rip-cage/mediators/${_rc_med}"
_rc_med_start_hook="${_rc_med_registry_dir}/start"
_rc_med_uid_file="${_rc_med_registry_dir}/run_as_uid"
_rc_med_health_hook="${_rc_med_registry_dir}/health_check"
_rc_med_ca_cert_file="${_rc_med_registry_dir}/ca_cert_path"
_rc_med_pid_file="/run/rip-cage-mediator-${_rc_med}.pid"

if [ ! -d "$_rc_med_registry_dir" ]; then
  echo "[rip-cage] ERROR: egress mediator '${_rc_med}' registry dir absent at ${_rc_med_registry_dir} — image may not have this mediator baked in. Add a MEDIATOR manifest entry and rebuild (ADR-001 fail-closed)." >&2
  exit 1
fi
if [ ! -f "$_rc_med_start_hook" ]; then
  echo "[rip-cage] ERROR: egress mediator '${_rc_med}' has no 'start' hook at ${_rc_med_start_hook} (ADR-001 fail-closed)." >&2
  exit 1
fi
if [ ! -f "$_rc_med_uid_file" ]; then
  echo "[rip-cage] ERROR: egress mediator '${_rc_med}' has no 'run_as_uid' file at ${_rc_med_uid_file} — required for uid-exemption loop prevention (ADR-026 D5; ADR-001 fail-closed)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fail-closed uid validation (ADR-001 / ADR-026 D5)
# ---------------------------------------------------------------------------
_rc_med_run_as_uid=$(cat "$_rc_med_uid_file" | tr -d '[:space:]')
if [ -z "$_rc_med_run_as_uid" ]; then
  echo "[rip-cage] ERROR: egress mediator '${_rc_med}' run_as_uid is empty — refusing to start (would run as root, voiding uid-exemption loop-prevention; ADR-001 fail-closed; ADR-026 D5)." >&2
  exit 1
fi
if [ "$_rc_med_run_as_uid" = "0" ] || [ "$_rc_med_run_as_uid" = "root" ]; then
  echo "[rip-cage] ERROR: egress mediator '${_rc_med}' run_as_uid='${_rc_med_run_as_uid}' is root — refusing to start as root (uid-exemption loop-prevention requires a non-root uid; ADR-001 fail-closed; ADR-026 D5)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Idempotency guard (F4): if the mediator is already running, skip.
# Check the PID file first; then fall back to checking for a process owned by
# the run_as_uid (handles the case where the PID file was left from a prior run
# but the process survived — e.g. a failed stop during rc down).
# ---------------------------------------------------------------------------
if [ -f "$_rc_med_pid_file" ]; then
  _rc_med_existing_pid=$(cat "$_rc_med_pid_file" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$_rc_med_existing_pid" ] && kill -0 "$_rc_med_existing_pid" 2>/dev/null; then
    echo "[rip-cage] init-mediator: ${_rc_med} already running (pid=${_rc_med_existing_pid}) — idempotent skip"
    exit 0
  fi
  # Stale PID file — remove it and re-launch.
  rm -f "$_rc_med_pid_file"
fi

# ---------------------------------------------------------------------------
# Launch the mediator: root → drop to run_as_uid via su.
# nohup ... & survives the docker exec session returning (F1 fix).
# The RIPCAGE_MEDIATOR_* vars in the environment of THIS root exec session are
# inherited by the su subprocess (su -m / su's default on Debian preserves the
# environment when running as root→non-root with -s /bin/sh, and the hook string
# can reference them directly). We also pass HOME explicitly because docker exec
# --user does not set HOME from /etc/passwd for the shell spawned here.
#
# The start hook is the BARE command (no inner su, no &) — the dispatcher owns
# both the uid-drop and the backgrounding (matches manifest-fragment.yaml annotation).
# ---------------------------------------------------------------------------
echo "[rip-cage] init-mediator: starting '${_rc_med}' as uid '${_rc_med_run_as_uid}'..."

# Resolve the numeric uid for HOME lookup and PID tracking.
_rc_med_home=$(getent passwd "$_rc_med_run_as_uid" 2>/dev/null | cut -d: -f6 || true)
if [ -z "$_rc_med_home" ]; then
  _rc_med_home="/tmp"
fi

# Build the env passthrough for RIPCAGE_MEDIATOR_* vars.
# We collect them from the current environment (injected by docker exec -e) and
# pass them explicitly into the su child via env(1). This survives across the
# su privilege drop on all Debian su variants.
_rc_med_env_pairs=""
while IFS= read -r _evar; do
  case "$_evar" in
    RIPCAGE_MEDIATOR_*)
      _rc_med_env_pairs="${_rc_med_env_pairs} ${_evar}"
      ;;
  esac
done < <(env | grep '^RIPCAGE_MEDIATOR_' | awk -F= '{print $1}')

# Build the env prefix for the start hook invocation.
# Each KEY=VALUE pair is shell-quoted via printf '%q' so that secret values
# containing spaces, quotes, or special chars are passed correctly to env(1).
# Without quoting, a secret like "Bearer x y" would split into two env args
# and the value would be silently truncated at the first space (F2 fix).
_rc_med_env_prefix="HOME=$(printf '%q' "${_rc_med_home}")"
for _ev in $_rc_med_env_pairs; do
  _ev_val=$(printenv "${_ev}" 2>/dev/null || true)
  # shellcheck disable=SC2163
  _rc_med_env_prefix="${_rc_med_env_prefix} ${_ev}=$(printf '%q' "${_ev_val}")"
done

# Launch the mediator via su: root→run_as_uid, nohup so it outlives this exec.
# Write the PID file so the idempotency guard works on resume.
# The log file is world-readable (agent can tail it for debugging).
_rc_med_log="/tmp/rip-cage-mediator-${_rc_med}.log"
# The start hook string may contain redirects (> /tmp/...) — run it via sh -c.
# We use `env` to pass RIPCAGE_MEDIATOR_* into the dropped process.
#
# F2 hardening: pass the start hook via a temp file instead of inline single-quote
# interpolation ('$(cat hook)') so that registry-controlled hooks containing single
# quotes do not break the outer shell string. The temp file is root-owned and
# removed after the su invocation.
_rc_med_start_tmp=$(mktemp /tmp/rip-cage-start-XXXXXX)
cat "${_rc_med_start_hook}" > "${_rc_med_start_tmp}"
chmod 0644 "${_rc_med_start_tmp}"
su -s /bin/sh "$_rc_med_run_as_uid" -c \
  "nohup env ${_rc_med_env_prefix} sh ${_rc_med_start_tmp} >> ${_rc_med_log} 2>&1 & echo \$!" \
  > "$_rc_med_pid_file" 2>/dev/null
rm -f "${_rc_med_start_tmp}"

_rc_med_launched_pid=$(cat "$_rc_med_pid_file" 2>/dev/null | tr -d '[:space:]')
echo "[rip-cage] init-mediator: '${_rc_med}' start hook launched (pid=${_rc_med_launched_pid:-unknown})"

# ---------------------------------------------------------------------------
# CA trust installation (F7 / rip-cage-ta1o.5.8)
# If the mediator registry has a ca_cert_path file pointing at the CA cert that
# the mediator generates, install it into the system trust store so the in-cage
# agent curl can verify the TLS MITM cert. This must happen AFTER the mediator
# starts (the CA is generated at first boot).
#
# Wait up to 10s for the CA cert to appear (mediator start is async).
# Tool-agnostic: driven by the optional ca_cert_path registry file; no mediator
# name is hardcoded here.
# ---------------------------------------------------------------------------
if [ -f "$_rc_med_ca_cert_file" ]; then
  _rc_med_ca_path=$(cat "$_rc_med_ca_cert_file" | tr -d '[:space:]')
  if [ -n "$_rc_med_ca_path" ]; then
    echo "[rip-cage] init-mediator: CA cert path configured at '${_rc_med_ca_path}' — waiting for cert..."
    _rc_med_ca_wait=0
    while [ "$_rc_med_ca_wait" -lt 20 ]; do
      if [ -f "$_rc_med_ca_path" ] && [ -s "$_rc_med_ca_path" ]; then
        break
      fi
      sleep 0.5
      _rc_med_ca_wait=$((_rc_med_ca_wait + 1))
    done
    if [ -f "$_rc_med_ca_path" ] && [ -s "$_rc_med_ca_path" ]; then
      cp "$_rc_med_ca_path" /usr/local/share/ca-certificates/rip-cage-mediator-ca.crt
      if update-ca-certificates > /dev/null 2>&1; then
        echo "[rip-cage] init-mediator: CA cert installed from '${_rc_med_ca_path}'"
        # Also set NODE_EXTRA_CA_CERTS in firewall-env for Claude Code (Node.js).
        # init-rip-cage.sh sources /etc/rip-cage/firewall-env, which passes env to the agent.
        if [ -f /etc/rip-cage/firewall-env ]; then
          # Only append if not already present.
          if ! grep -q 'NODE_EXTRA_CA_CERTS' /etc/rip-cage/firewall-env 2>/dev/null; then
            printf '\nexport NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/rip-cage-mediator-ca.crt\n' \
              >> /etc/rip-cage/firewall-env
          fi
        fi
      else
        echo "[rip-cage] WARN: init-mediator: update-ca-certificates failed — curl may reject the mediator's TLS cert" >&2
      fi
    else
      echo "[rip-cage] WARN: init-mediator: CA cert not found at '${_rc_med_ca_path}' after 10s — skipping CA install (curl may reject MITM cert)" >&2
    fi
    unset _rc_med_ca_wait _rc_med_ca_path
  fi
fi

# ---------------------------------------------------------------------------
# Optional health check: gate readiness before returning.
# Mirrors the pattern from init-rip-cage.sh section 12 daemon lifecycle.
# ---------------------------------------------------------------------------
if [ -f "$_rc_med_health_hook" ]; then
  echo "[rip-cage] init-mediator: running health_check for '${_rc_med}'..."
  _rc_med_health_ok=0
  _rc_med_health_attempts=0
  sleep 1
  while [ "$_rc_med_health_attempts" -lt 10 ]; do
    _rc_med_health_attempts=$((_rc_med_health_attempts + 1))
    if su -s /bin/sh "$_rc_med_run_as_uid" -c "$_rc_med_health_hook" 2>/dev/null; then
      _rc_med_health_ok=1
      break
    fi
    sleep 1
  done
  if [ "$_rc_med_health_ok" -eq 1 ]; then
    echo "[rip-cage] init-mediator: health_check PASSED for '${_rc_med}'"
  else
    echo "[rip-cage] WARN: init-mediator: health_check failed after ${_rc_med_health_attempts} attempts — mediator may not be ready (cage continues per ADR-005 D10)" >&2
  fi
  unset _rc_med_health_ok _rc_med_health_attempts
fi

echo "[rip-cage] init-mediator: done"
