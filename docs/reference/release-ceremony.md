# Release ceremony

The single agent-facing checklist for cutting a rip-cage release. The global `/release` skill does **not** know the rip-cage-specific steps (GHCR visibility flip, `scripts/update-formula-sha.sh`, multi-arch manifest smoke, the two-repo Homebrew tap sync) — this doc is the source of truth for them.

> **Why this exists:** the ceremony used to be scattered across `CHANGELOG.md`, ADR-008 (D6/D8), and a closed bead's design. A new agent tagging a release reconstructed the steps from those fragments. This is the consolidation.

The post-tag sequence is **time-sensitive**: the Homebrew formula's stable `url` is broken between the tag push and the sha256-update commit (`brew install --HEAD` covers that window). Move through steps 4–7 promptly.

There is also an earlier, expected transient: between the version's PRs **merging to `main`** and the **tag being pushed** (step 3), a `brew install --HEAD` user's first `rc up` will try `docker pull ...:$VERSION`, get a 404, and fall back to a local build (~5–10 min). This is acceptable — `--HEAD` users opt into bleeding-edge — and resolves automatically once the tag publishes the image. No action needed; just don't be alarmed by 404s in that window.

## Prerequisites

- `VERSION` already bumped to the target `X.Y.Z` on `main` (the `/release` skill or a prior bump did this — `release.yml` verifies the tag matches `VERSION`).
- All PRs targeting this version merged to `main`.
- You are on a clean `main` (`git status` clean, `git pull` current).

## Checklist

### 1. Pre-flight

```bash
bd preflight        # clean — no blocking issues
```

### 2. Pre-tag gate — run the FULL host suite (not lint-only)

Both gates must pass **before** tagging:

```bash
make lint                          # pinned koalaman/shellcheck:v0.11.0 (same image CI runs)
bash tests/run-host.sh --host-only # the FULL ordered host suite — NOT a per-changed-file subset
```

> **Why the full suite, not just lint or the changed tests** *(v0.9.0 lesson A)*: an epic close that runs only lint plus the beads it touched lets a **sibling-decayed** control in an untouched test file survive to the release gate. v0.9.0 shipped a stale floor-protection assertion (in `test-pi-substrate-mounts.sh`, asserting retired symlink wiring) precisely because the close ran a per-bead subset. A decayed positive control in an untouched file escapes every per-bead / per-changed-file scope but **not** the full ordered run. `make lint` is the local==CI lint gate; `tests/run-host.sh --host-only` is the local==CI host gate (one driver, denylist-default classification — ADR-008 D4). Local must equal CI by construction; don't tag on a subset.

### 3. Tag and push

```bash
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

This triggers `release.yml`, which:
- verifies the tag matches `VERSION`,
- builds **native per-arch** images (amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`) from the maintainer-composed default manifest (`RC_MANIFEST_GLOBAL=dist/default-tools.yaml ./rc generate-dockerfile`),
- merges them into a multi-arch manifest and pushes `ghcr.io/jsnyde0/rip-cage:$VERSION` + `:latest`.

**Watch the run.** If CI fails, see [Troubleshooting](#troubleshooting-if-ci-fails) below before doing anything else.

### 4. First-time-only — flip GHCR visibility to Public

GHCR packages default to **private** on first push of a *new* package. Until flipped, unauthenticated `docker pull` from end users fails silently and falls back to a 5–10 min local build — defeating ADR-008 D6's first-run-fast promise.

Set visibility to **Public**:

> https://github.com/users/jsnyde0/packages/container/rip-cage/settings

(Only needed once for the lifetime of the package, not per release.)

### 5. Pin the Homebrew formula sha

```bash
./scripts/update-formula-sha.sh
```

This waits for the source tarball to be downloadable, then patches **both** the versioned tarball `url` tag **and** the `sha256` in `Formula/rip-cage.rb`, and syncs the copy to the sibling tap clone (`../homebrew-rip-cage/`) if present.

> **The `url` and `sha256` MUST move together** *(v0.9.0 lesson C / `rip-cage-homebrew-formula-url-sha-coupling`)*: a stale `url` against a fresh `sha256` ships a formula whose tarball fails checksum and breaks `brew install` for **every** user on that release. This shipped broken on v0.5.0/v0.5.1 before the script was fixed to `sed` the `url` from `VERSION` alongside the `sha256`.

### 6. Verify the formula end-to-end (do NOT skip — eyeballing the diff is insufficient)

The actual breakage point is `brew`'s own download+checksum, not the formula text. Verify against the *pushed* formula:

```bash
# (a) cross-check the live tarball sha against the pinned sha
curl -sL "https://github.com/jsnyde0/rip-cage/archive/refs/tags/v$(cat VERSION).tar.gz" | shasum -a 256
#     ^ must equal the sha256 in Formula/rip-cage.rb

# (b) fast-forward the LOCAL tap clone so brew verifies the pushed formula, not a stale local copy
git -C "$(brew --repository)/Library/Taps/jsnyde0/homebrew-rip-cage" pull --ff-only

# (c) exercise brew's real download + checksum path
brew fetch jsnyde0/rip-cage/rip-cage   # exit 0 == tarball downloads and checksum matches
```

> The ceremony spans **two repos** — the main repo's `Formula/rip-cage.rb` and the sibling `../homebrew-rip-cage` tap. `update-formula-sha.sh` patches and syncs both but does **not** run `brew fetch` — that stays a manual gate (step 6c).

### 7. Commit and push the formula pin

```bash
git commit -am "release: pin v$(cat VERSION) sha256"
git push
```

(And `git -C ../homebrew-rip-cage push` if the script synced the sibling tap and it isn't auto-pushed.)

### 8. Multi-arch smoke check

```bash
docker manifest inspect "ghcr.io/jsnyde0/rip-cage:$(cat VERSION)"
#   ^ must list BOTH linux/amd64 and linux/arm64

# On a clean macOS box (ideally a different arch than you built on):
brew install jsnyde0/rip-cage/rip-cage
```

### 9. Cut the GitHub release

```bash
gh release create "v$(cat VERSION)" --notes-from-tag
#   ^ or paste the CHANGELOG section for this version
```

## Troubleshooting (if CI fails)

### CI tooling must be arch-matched *(v0.9.0 lesson B)*

The v0.9.0 tag's first CI run **failed and published nothing**: the native arm64 build downloaded the **amd64** `yq` binary → `Exec format error` (exit 126) → the manifest-merge job skipped → no image. `yq` is a CI dependency of the `rc generate-dockerfile` path; v0.9.0 was the first release to exercise the native arm64 runner. The fix pins `yq_linux_${matrix.arch}` (see `ci-new-tool-dependency-needs-arch-matrix-coverage`). **Any new CI tool fetched by architecture must select per `matrix.arch`** — this is a `release.yml` invariant, surfaced here because it only bites on a real tag.

### Re-pointing a tag is safe — but only while nothing has consumed it

A release-CI failure that **publishes nothing usable** (manifest merge skipped, no image at `:VERSION`/`:latest`) means the tag can be **re-pointed** rather than burning a fresh version:

```bash
git tag -d "v$VERSION"
git push origin ":v$VERSION"       # delete remote tag
# ...land the fix on main, then re-tag at the fix commit
```

This is valid **only** while nothing downstream has consumed the tag — i.e. the formula isn't pinned to it, GHCR `:VERSION`/`:latest` don't serve it, and no GitHub release exists yet. Once any of those consume the tag, cut a new patch version instead.

> Same-class trap on the lint gate: the v0.4.x line burned **three tags** when CI's apt-installed shellcheck 0.9.0 emitted info findings local 0.11.0 did not — fixed by the pinned-image local==CI invariant (ADR-008 D4). The pre-tag full-suite gate (step 2) is what keeps these from surfacing post-tag.

## Worked example — v0.9.0

The first cut after the `wlwc` + `ta1o` epics, which surfaced all three gates above:

- `f494a31` — removed a stale floor-protection control that the per-bead close scope missed (would have been caught by step 2's full suite).
- `224c150` — pinned `yq` per `matrix.arch` (the arm64 CI failure).
- `09f1394` — pinned the v0.9.0 formula sha.

## canonical_refs

- ADR-008 D4 (local==CI invariant; pinned-tool lint gate; release.yml-invalidation clause), D6 (GHCR multi-arch publish + visibility flip), D7 (Homebrew primary), D8 (tap-sync + url/sha coupling + brew-fetch gate)
- ADR-013 D5 (CI tiers — full host-only suite), D6 (host-only determinism, run-all driver)
- ADR-001 (fail-loud — a skipped/missing publish must fail loud before shipping)
- bd memories: `epic-close-reverify-delta-and-carry-forward-sweep`, `ci-new-tool-dependency-needs-arch-matrix-coverage`, `rip-cage-homebrew-formula-url-sha-coupling`, `ci-shellcheck-version-divergence`
