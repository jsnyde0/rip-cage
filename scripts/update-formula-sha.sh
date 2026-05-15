#!/usr/bin/env bash
# update-formula-sha.sh — compute sha256 of the current VERSION's source
# tarball from GitHub and patch Formula/rip-cage.rb. Idempotent; safe to run
# multiple times.
#
# Run this AFTER pushing a vX.Y.Z tag (so GitHub's archive endpoint serves the
# tarball). Retries up to ~2 min for tag-to-tarball propagation.
#
# Release ceremony: see docs/decisions/ADR-008-open-source-publication.md D6/D8.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMULA="${REPO_ROOT}/Formula/rip-cage.rb"
VERSION_FILE="${REPO_ROOT}/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Error: VERSION file not found at $VERSION_FILE" >&2
  exit 1
fi
if [[ ! -f "$FORMULA" ]]; then
  echo "Error: Formula not found at $FORMULA" >&2
  exit 1
fi

version=$(cat "$VERSION_FILE")
tarball_url="https://github.com/jsnyde0/rip-cage/archive/refs/tags/v${version}.tar.gz"

echo "Computing sha256 for ${tarball_url}..."

sha256=""
for attempt in 1 2 3 4 5 6; do
  if sha256=$(curl -sfL "$tarball_url" | sha256sum | awk '{print $1}') && [[ -n "$sha256" ]]; then
    break
  fi
  sha256=""
  echo "  attempt ${attempt} failed (tag not yet propagated?); retrying in 20s..."
  sleep 20
done

zero_sha="0000000000000000000000000000000000000000000000000000000000000000"
if [[ -z "$sha256" || "$sha256" == "$zero_sha" ]]; then
  echo "Error: failed to compute sha256 for v${version} after 6 attempts." >&2
  echo "  Has the v${version} tag been pushed to GitHub? Try:" >&2
  echo "    curl -fL ${tarball_url} | sha256sum" >&2
  exit 1
fi

# Patch the formula. Match any 64-hex-char sha256 line (placeholder or prior real value).
sed -i.bak -E "s|sha256 \"[a-f0-9]{64}\"|sha256 \"${sha256}\"|" "$FORMULA"
rm -f "${FORMULA}.bak"

echo "Updated ${FORMULA#${REPO_ROOT}/}"
echo "  version: ${version}"
echo "  sha256:  ${sha256}"

# Sync to the homebrew tap repo if it exists as a sibling directory.
TAP_FORMULA="${REPO_ROOT}/../homebrew-rip-cage/Formula/rip-cage.rb"
if [[ -f "$TAP_FORMULA" ]]; then
  cp "$FORMULA" "$TAP_FORMULA"
  echo "Synced to homebrew-rip-cage tap repo"
  echo ""
  echo "Next: review and commit both repos:"
  echo "  git diff Formula/rip-cage.rb"
  echo "  git add Formula/rip-cage.rb"
  echo "  git commit -m 'release: pin v${version} sha256'"
  echo "  git push"
  echo ""
  echo "  cd ../homebrew-rip-cage"
  echo "  git add Formula/rip-cage.rb"
  echo "  git commit -m 'rip-cage ${version}'"
  echo "  git push"
else
  echo ""
  echo "Next: review the diff and commit:"
  echo "  git diff Formula/rip-cage.rb"
  echo "  git add Formula/rip-cage.rb"
  echo "  git commit -m 'release: pin v${version} sha256'"
  echo "  git push"
  echo ""
  echo "Then sync to the tap repo (homebrew-rip-cage):"
  echo "  cp Formula/rip-cage.rb ../homebrew-rip-cage/Formula/rip-cage.rb"
  echo "  cd ../homebrew-rip-cage && git add -A && git commit -m 'rip-cage ${version}' && git push"
fi
