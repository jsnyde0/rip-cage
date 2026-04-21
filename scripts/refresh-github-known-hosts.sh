#!/usr/bin/env bash
# Refresh GitHub SSH host keys in ssh/known_hosts.github.
# Run manually when GitHub rotates its SSH keys.
# Usage: bash scripts/refresh-github-known-hosts.sh
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "error: ssh-keygen is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../ssh/known_hosts.github"

echo "Fetching github.com SSH host keys from api.github.com/meta..."
keys=$(curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[]')

ed25519_key=$(echo "$keys" | grep ssh-ed25519)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf 'github.com %s\n' "$ed25519_key" > "$tmp"
fp=$(ssh-keygen -l -f "$tmp" | awk '{print $2}' | sed 's/^SHA256://')

{
  echo "# GitHub SSH host keys — pinned from api.github.com/meta (.ssh_keys[])."
  echo "# Fetched: $(date +%Y-%m-%d). SHA256_ED25519: $fp"
  echo "# Refresh: scripts/refresh-github-known-hosts.sh"
  while IFS= read -r key; do
    echo "github.com $key"
  done <<< "$keys"
} > "$OUT"

echo "Written to $OUT"
