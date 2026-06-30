#!/usr/bin/env bash
# pi-wrapper.sh — Rip Cage generic pi launch shim (rip-cage-l72i.1)
#
# This is the TEMPLATE for the generic pi launch wrapper. At build time, rc build
# concatenates launch_args declared across composed recipe fragments (in fragment
# order — guard fragment first) and bakes a wrapper at /usr/local/bin/pi that
# execs the real pi binary with the assembled args + "$@".
#
# This source file is the human-readable TEMPLATE — no recipe-specific paths,
# no flags, no extension paths baked here. rc build generates the real image
# wrapper from this pattern plus the assembled launch_args.
#
# ADR-027 D4 (FIRM principle): no hardcoded cross-recipe paths in any launch leg.
# Recipes contribute launch args via manifest launch_args, assembled at rc build.
#
# ADR-005 D12: rc owns the composition interface (assembling the shim from
# manifest-declared launch_args), NOT blessing any specific tool.
#
# Guard wiring (extension flags for the DCG guard or any other guard) is contributed
# by the relevant recipe fragment and assembled into this shim at build time by
# rc build. Dropping a guard fragment removes its flags. Zero wrapper edits needed
# to add or remove any extension.
#
# ADR-027 D1/D3: guard wiring stays root-owned on its OWN separate load path,
# NOT inside extensions/ (olen retired).

set -euo pipefail

REAL_PI="/usr/bin/pi"

# Fail loud if the real pi binary is missing (Dockerfile regression)
if [[ ! -x "$REAL_PI" ]]; then
  echo "[rip-cage pi-shim] FATAL: real pi binary not found at ${REAL_PI}" >&2
  exit 1
fi

# Assembled launch args — baked in at image build time from manifest launch_args.
# rc build writes the real wrapper with the assembled args; this placeholder
# shows the generic exec pattern (ASSEMBLED_ARGS is empty in the template).
# In the image wrapper, ASSEMBLED_ARGS contains the concatenated launch_args
# from all composed fragments in fragment order.
ASSEMBLED_ARGS=()

# Fail loud if any -e <ext-path> arg is missing (guard wiring not baked).
# This check is generic — works for any extension path contributed by any fragment.
_prev=""
for _arg in "${ASSEMBLED_ARGS[@]+"${ASSEMBLED_ARGS[@]}"}"; do
  if [[ "$_prev" == "-e" && ! -f "$_arg" ]]; then
    echo "[rip-cage pi-shim] FATAL: declared extension missing at ${_arg} — refusing to launch" >&2
    exit 1
  fi
  _prev="$_arg"
done

exec "$REAL_PI" "${ASSEMBLED_ARGS[@]+"${ASSEMBLED_ARGS[@]}"}" "$@"
