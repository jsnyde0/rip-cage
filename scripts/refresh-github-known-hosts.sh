#!/usr/bin/env bash
# Refresh GitHub SSH host keys in ssh/known_hosts.github.
# Run manually when GitHub rotates its SSH keys.
# Usage: bash scripts/refresh-github-known-hosts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/../ssh/known_hosts.github"

echo "Fetching github.com SSH host keys from api.github.com/meta..."
keys=$(curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[]')

{
  echo "# GitHub SSH host keys — pinned from api.github.com/meta (.ssh_keys[])."
  echo "# Fetched: $(date +%Y-%m-%d). SHA256_ED25519: $(ssh-keygen -l -f /dev/stdin <<< "github.com $(echo "$keys" | grep ssh-ed25519)" 2>/dev/null | awk '{print $2}' || echo 'run ssh-keygen manually to verify')"
  echo "# Refresh: scripts/refresh-github-known-hosts.sh"
  while IFS= read -r key; do
    echo "github.com $key"
  done <<< "$keys"
} > "$OUT"

echo "Written to $OUT"
