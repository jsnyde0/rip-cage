#!/usr/bin/env bash
# Throwaway probe for rip-cage-ely4.10 / ely4.7.2. Deleted before commit.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(mktemp -d /private/tmp/rc-probe-XXXXXX)
mkdir -p "$ROOT/home" "$ROOT/proj" "$ROOT/bin"
cat > "$ROOT/bin/msb" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${P_LOG}"
case "${1:-}" in --version) echo "msb 0.6.18-test-shim"; exit 0 ;; esac
: > "${P_SENTINEL}"
echo "shim: msb invoked: $*" >&2
exit 1
SH
chmod +x "$ROOT/bin/msb"
cat > "$ROOT/ok.yaml" <<EOF
image: rip-cage:latest
workdir: /workspace
mounts:
  - "${ROOT}/proj:/workspace"
network:
  policy: none
  allow:
    - "api.anthropic.com:tcp:443"
EOF

run() {
  (
    PATH="$ROOT/bin:$PATH"
    XDG_CONFIG_HOME="$ROOT/home/.config"
    P_LOG="$ROOT/msb.log"
    P_SENTINEL="$ROOT/SENT"
    RC_CAGE_CONF="$ROOT/ok.yaml"
    RC_MULTIPLEXER="$1"
    export PATH XDG_CONFIG_HOME P_LOG P_SENTINEL RC_CAGE_CONF RC_MULTIPLEXER
    shift
    ./rc "$@"
  ) 2>&1
}

echo "--- A: dry-run baseline, mux none ---"
run none up --dry-run "$ROOT/proj" | grep -E '^Would run: msb create' | head -1 | cut -c1-140

echo "--- B: unknown multiplexer must refuse with no msb subcommand ---"
rm -f "$ROOT/SENT" "$ROOT/msb.log"
run nosuchmux up "$ROOT/proj"
echo "exit=$?"
if [[ -f "$ROOT/SENT" ]]; then echo "sentinel: PRESENT (fail-open)"; else echo "sentinel: absent (refused)"; fi
echo "msb log: $(cat "$ROOT/msb.log" 2>/dev/null | tr '\n' '|')"

echo "--- C: declared multiplexer reaches the launch ---"
rm -f "$ROOT/SENT" "$ROOT/msb.log"
run herdr up --dry-run "$ROOT/proj" | grep -cE '^Would run: msb create'

echo "ROOT=$ROOT"
