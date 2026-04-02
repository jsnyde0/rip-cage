# Fixes: e2e-validation-fixes
Date: 2026-04-02
Review passes: 1

## Critical
- **rc:422-436** — Beads redirect resolution bypassed `validate_path` and `RC_ALLOWED_ROOTS`, allowing a crafted `.beads/redirect` to mount arbitrary host directories into the container. Fixed: reject absolute paths/control chars, validate resolved path against allowed roots before mounting. (ADR-003 D3 violation)

## Important
- **rc:246** — `container_name()` could produce empty string for pathological inputs after sed strips all leading dots/dashes. Fixed: guard against empty name with error exit.
- **rc:341-344** — Credential directory artifact guard silently swallowed failures when `rmdir` failed on non-empty directory, causing silent credential extraction failure. Fixed: emit explicit warning when directory persists after rmdir.
- **rc:716, docs** — Schema declared `init` path as `required: true` but implementation defaults to `.`. Fixed: schema updated to `required: false, default: "."` in rc, design doc, and ADR-003.

## Minor
- None applied (comment clarity items discarded as cosmetic)

## ADR Updates
- **ADR-003 D5**: `init` path schema corrected to `required: false` with `default: "."`
- No other ADR changes needed — beads redirect validation now complies with ADR-003 D3

## Discarded
- Comment clarity on sed pattern (impl reviewer) — cosmetic, the code is clear enough
- init-rip-cage.sh redirect documentation gap (impl reviewer) — the mount is transparent to the init script, no comment needed
- Redundant port reads between rc and init-rip-cage.sh (arch reviewer) — intentional defense-in-depth; both components can work independently
