# Tap release-path review — who can publish rip-cage, and what users can verify (2026-10-03)

Source bead: `dotpi-wyf.7` (dotpi tracker). Findings parent: `rip-cage-jnxo`. Reviewer seat: `driver:dotpi-wyf.7`, dispatched by `brain:dotpi`. Image-content pinning (`FROM` by tag, `@latest` npm installs, `curl | sh`) is already `rip-cage-p4ss.5` from the isolation-boundary review and is not re-filed here.

Defensive, read-only review. No code in rip-cage or homebrew-rip-cage was edited, nothing was pushed, and no GitHub setting was changed. Probes were reads only: `gh api` on repo, branch-protection, ruleset and Actions settings; anonymous GHCR manifest and tag-list queries; a download of the v0.13.1 source tarball; local `git archive` of the same tag; `git tag -v` and `%G?` signature checks.

## What was reviewed

The path from a maintainer's commit to code running on a user's host:

| Step | Artifact | What pins it today |
|---|---|---|
| 1. Tag `vX.Y.Z` pushed | lightweight git tag | nothing — no signature, no tag protection |
| 2. `release.yml` builds and pushes the image | `ghcr.io/jsnyde0/rip-cage:X` and `:latest` | GitHub account + Actions pinned by mutable tags |
| 3. `update-formula-sha.sh` pins the tarball | formula `url` + `sha256` | whatever GitHub served at pin time |
| 4. Formula copied to the tap and pushed | `homebrew-rip-cage/Formula/rip-cage.rb` | GitHub account; no branch protection, unsigned commits |
| 5. User runs `brew install` / `brew upgrade` | `rc` in `libexec` | formula `sha256` (the one real pin in the chain) |
| 6. First `rc up` pulls the image | `rip-cage:latest` locally | tag `:RC_VERSION` only — no digest, no signature |

**What a compromised tap means.** The formula is Ruby that `brew` runs on the **host**, outside any cage. A push to the tap's `main` can repoint `url` + `sha256` to a trojaned tarball or rewrite `install`. `brew` auto-updates taps, so it reaches every user at their next `brew upgrade` — including the maintainer's own host (`brew list --versions rip-cage` → `0.13.1`), where the GitHub keys and every project live. The trojaned `rc` then runs with Docker and msb access, and can also change the default registry so every cage boots an attacker image. This is the highest-leverage point in the whole system: it sits *outside* the containment that rip-cage exists to provide.

## Ranked findings

| Rank | Bead | Sev | Finding | Status |
|---|---|---|---|---|
| 1 | `rip-cage-jnxo.1` | high | **Neither repo has any GitHub-side guard.** No branch protection, no rulesets, no tag protection, `allowed_actions: all`, `sha_pinning_required: false`. One push credential publishes a tap formula (host code execution at every user's next `brew upgrade`) or a `v*` tag (overwrites GHCR `:X` and `:latest`). The same SSH key sits on the host where non-caged agent seats run git; "never push" is prose only. | **Confirmed** (live `gh api`) |
| 2 | `rip-cage-jnxo.2` | med-high | `release.yml` holds `packages: write` and runs third-party Actions pinned by **mutable major tags** (`@v3`, `@v4`, `@v6`). A moved upstream tag pushes a trojaned image under a genuine release tag, with no repo diff. | Confirmed (source + settings) |
| 3 | `rip-cage-jnxo.3` | med | Release publishes **no signature or provenance** for the image (no cosign, no build attestation; zero `sha256-*` referrer tags in GHCR). `rc` pulls by tag. p4ss.5's "pull by digest + verify" has nothing to verify against, and the digest is unknown when the tarball is cut. Blocks the GHCR half of `rip-cage-p4ss.5`. | Confirmed (source + registry) |
| 4 | `rip-cage-jnxo.4` | med | The formula `sha256` is **trust-on-first-use**: the script hashes whatever GitHub serves, and ceremony step 7a re-checks GitHub against itself. Measured: GitHub's v0.13.1 tarball, decompressed, is **byte-identical** to a local `git archive` of the tag (`ec1ed9b4…`), so a local cross-check is cheap and exact. | Confirmed (executed) |
| 5 | `rip-cage-jnxo.5` | med | **Tags are lightweight and unsigned; tap commits are unsigned** (`git tag -v` → not a tag object; `%G?` → `N` on all 20 tap commits). Provenance rests only on GitHub account integrity, and a "require signatures" rule has nothing to enforce yet. | Confirmed (executed) |
| 6 | `rip-cage-jnxo.6` | low | **Published releases are mutable.** The ceremony sanctions tag re-pointing; `release.yml` overwrites an existing `:X` and always moves `:latest`, with no check that the tag is on `main`. A version name is not a stable identity, which undercuts any later digest pin. | Confirmed (source) |
| 7 | `rip-cage-jnxo.7` | low | **Tap hygiene.** The two hand-synced formula copies already differ (line 39). The tap README and ADR-008 D7 name `jq + tmux`; the formula depends on `jq + yq`. A stale "PLACEHOLDER" comment remains. `install` ships the whole tree, 455 of 774 files under `tests/`. | Confirmed (executed) |

Each bead carries evidence, the gap, a fix direction and its own `## Verification target`.

## Checked and holding

- The v0.13.1 formula `sha256` (`7f3d8f49…`) matches the tarball GitHub serves today.
- `release.yml` verifies the tag against `VERSION` before building, and uses the short-lived `GITHUB_TOKEN`, not a stored PAT.
- Default workflow permissions are `read`; `packages: write` is scoped to the build and merge jobs only.
- Workflows can't approve pull requests (`can_approve_pull_request_reviews: false`).
- `ci.yml` triggers on `pull_request`, not `pull_request_target`, so fork PRs get no secrets and no write token.
- Per-arch images are pushed by digest and stitched into the manifest by digest refs; GHCR `:0.13.1` and `:latest` both resolve to `sha256:f073b76f…` today.
- The url/sha coupling bug (`rip-cage-ndz`) stays fixed: the script moves both together.

## Suggested order

1 and 2 first: they are settings and pin changes with no design question, and they close the cheapest takeover paths. Then 5 (signing), which 1's "require signatures" rule needs. Then 4. Then 3, after the ADR call below. 6 and 7 can ride along with any release.

## Decisions that want an ADR (proposed, not written)

1. **How the image digest reaches `rc`** (ADR-008 D6 evolution, FLEXIBLE). Today the formula pins the CLI but the image is trust-on-tag. Options: (a) the **tap formula carries the digest** — formula `install` writes `libexec/IMAGE_DIGEST`, so the tap commit pins both the CLI and the image; one more value for the post-tag script to patch. (b) **`rc` verifies a signature** at pull time — cosign keyless or `gh attestation verify`; needs a tool most hosts lack, so it would be optional, which means it is skipped. (c) **A digest file published as a release asset** — needs its own integrity anchor, so it collapses back into (a). Recommendation: **(a), with signing (jnxo.3) as the publish-side half**, because it reuses the one pin users already trust and adds no host dependency. Breaks if `--HEAD` installs must also pin; they would fall back to tag pulls, as today.
2. **Release-path trust model** (ADR-008 D8 addendum). Write down who may publish (a maintainer-held signing key, not any credential on the host), that tags and version images are immutable once consumed, and that agent seats never hold a push-capable credential for the tap. Today this is implicit and only enforced by prose.
3. **Retire the hand-copied formula** (ADR-008 D8). Two formula homes with a `cp` between them already drift; pick the tap as the single home, or add a CI check that fails on diff.

## Human checks this review could not do

- Confirm **2FA or a passkey** is on the `jsnyde0` GitHub account. The API does not expose it to the owner token used here.
- Confirm no **deploy keys or fine-grained PATs** with write access to `homebrew-rip-cage` exist beyond the maintainer's own (`gh api repos/jsnyde0/homebrew-rip-cage/keys` returned none; PATs are only visible in account settings).
