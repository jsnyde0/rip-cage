# Safety Stack

The layers that contain a caged agent, and what each one actually covers. They target the threat model in [ADR-024](../decisions/ADR-024-prompt-injection-threat-model.md): honest-mistake accidents, plus a non-adversarial agent following hostile instructions injected via fetched content or workspace files.

**Layers, not walls.** No single layer stops a motivated attacker, and none is claimed to.

## The floor — always on

These hold no matter what you compose into the image:

- **The microVM boundary.** msb runs the cage as a separate kernel on virtualized hardware.
- **Default-deny egress and DNS** at that boundary. Nothing leaves except the hosts the config names. See [egress.md](egress.md).
- **Credentials the guest never holds.** msb `--secret` binds a credential to named hosts and injects it on the wire; the guest sees a placeholder. See [secret-posture.md](secret-posture.md).
- **A non-root agent user** with narrowly scoped sudo (see [whats-in-the-box.md](whats-in-the-box.md)).
- **The protected-paths mount rule** — host-side, before the cage exists. See below.
- **The floor probe on the built image** — it inspects the artifact, not a declaration describing it. See below.

## The floor probe

`/usr/local/lib/rip-cage/floor-probe.sh` is baked `root:root 0555` into the image. Init runs it **before any other work** at every boot, and `rc test` runs it before any other suite. There is no opt-out; a failing check stops the boot.

It checks the artifact: that the agent user is non-root and its home is where the mounts land, that sudo's scope is what the Dockerfile set, that release-marker mode and owner are right, that the git-hooks deny entry is present, that each floor wrapper on `PATH` resolves to the floor's own file **as an interactive login shell resolves it**, that guard files are root-owned and not world-writable, and that `bd`, `python3` and the mise trust path are where init expects them. Twenty checks; the probe's own file header carries the list with the `cage/Dockerfile` line each one guards.

Two of those checks exist because the obvious version was too weak to catch the real damage:

- **Home, not just non-root.** A `USER <anyone>` line in an extension image boots silently with `$HOME` somewhere else, while every host mount stays stranded at `/home/agent`. Asserting non-root would pass that image.
- **PATH resolution, not PATH order.** Presence on `PATH` proves nothing when an extension's `ENV PATH` prepend shadows `/usr/local/bin` in the login shell, so the check resolves each wrapper through `zsh -i`.

Nothing here asserts read-only-ness from a mount table: `mount -o remount,rw` returns 0 and flips the guest's table while the write still fails `EROFS`, so only an attempted write proves it. Mount modes are the protected-paths rule's half anyway.

Rationale: a check that reads a declaration can be lied to by the declaration ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D5b).

## The protected-paths mount rule

A shipped list of known credential locations — ssh, cloud, gpg, kube, env files — as plain data an operator may edit. Before any msb call, `rc up` refuses to launch a config that mounts a listed path, covers any listed path found **inside** a mounted tree, and aborts if the list is unreadable. If msb cannot express a cover, `rc up` refuses rather than proceeding.

This is what stops a config from showing your ssh keys into a cage. The floor probe guards what is *in* the image; this guards what is *mounted into* the cage ([ADR-031](../decisions/ADR-031-opinionated-distribution-of-microsandbox.md) D2/D5d, [ADR-023](../decisions/ADR-023-secret-path-mount-denylist.md)). Resolution order and the one-shot override are in [cli-reference.md](cli-reference.md#the-protected-paths-refusal).

The list lives host-side only — `$RC_PROTECTED_PATHS`, `$XDG_CONFIG_HOME/rip-cage/protected-paths`, or the copy beside `rc` — never a path a cage config can point at. A caged agent that could edit the list could delete the line protecting the thing it wants, which would make every other mount-side rule advisory.

## bypassPermissions, and the deny rules that survive it

Claude Code runs with `bypassPermissions` in `settings.json`, so the permission allowlist does not gate commands. The `permissions.deny` entries **do** still fire — `Write(.git/hooks/*)` and `Edit(.git/hooks/*)` block matching tool calls even in bypass mode, because deny is enforced by the permissions system independently of the mode.

The `permissions.allow` array is therefore documentation of intent rather than a control under this mode. Read it in `cage/agent/settings.json`; this page deliberately does not copy the list, because a copy drifts.

## Command guards — composable, not floor

The base image bakes **no** PreToolUse command-guard hook. A guard is something you compose ([ADR-025](../decisions/ADR-025-host-adoptable-dcg-policy.md) D2, [ADR-026](../decisions/ADR-026-containment-mediation-identity.md) D2: command-string policy is composable, not floor). Omitting one means no command-guard for that class of commands; everything under "The floor" above still holds.

`examples/dcg/` is one such recipe — a destructive-command guard whose rules match the whole command string unanchored, so chaining with `&&`, `;` or `||` does not slip past them. It is an example, not a blessed default: rip-cage names no tool ([ADR-005 D12](../decisions/ADR-005-ecosystem-tools.md)).

> **Why no compound-command blocker?** One existed until 0.6.0. Its only real purpose was defeating permission-allowlist prefix-matching — Claude Code matches the *first* command, so an allowlisted `git add` followed by `&& rm -rf` could slip through. Under `bypassPermissions` the allowlist gates nothing, so that protection is moot, and a whole-command-matching guard covers the destructive class regardless of chaining. See [ADR-002](../decisions/ADR-002-rip-cage-containers.md) D5.

## Verifying it

```bash
rc test <cage-name>      # floor probe first, then the rest of the suite
```

The suite runs against your composed image. A check that depends on a recipe you did not compose reports `SKIP` with a reason.
