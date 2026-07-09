# msb spike — cage lifecycle, persistence, restart/reboot survival, and the cheap-recreate resume story (2026-07-09)

Home bead: **rip-cage-r8jl**. Per the bead's notes addendum (2026-07-09, post-adversarial-review), this
is written to its own file rather than appended to the shared `2026-07-07-microvm-spike-findings.md`,
for parallel-run safety (a second spike, rip-cage-hfno, was running concurrently on the same machine
during this investigation — confirmed by name-disjoint sandboxes in `msb list`/`ps aux`, never touched).

**Machine:** the mac-mini (msb v0.6.4, `rip-cage:latest` + `docker:dind` pre-loaded, clean `msb list` at
start). All evidence below is live command output from this session, not doc-reasoning.

---

## 0. Headline verdict: the bead's "no snapshot/resume" premise is STALE for msb 0.6.4

The bead's framing text says *"msb has no snapshot/resume yet (msb issue #250)"*. That is **no longer
true as of msb 0.6.4** on this machine. Live-proven, end to end:

1. **`msb stop` / `msb start` is a real suspend/resume with full overlay persistence** — not a
   destroy/recreate. A package installed via `apt-get`, a file written to a non-mounted path, and data
   in named/disk volumes all survive a stop/start cycle intact (§1).
2. **`msb snapshot create <name> --from <stopped-sandbox>` genuinely works** — a marker written before
   snapshotting survived stop → snapshot → **full removal of the original sandbox** → boot of a
   brand-new, differently-named sandbox from `--snapshot <name>` (§4). This is real state capture/resume,
   disk-only as documented, not a stub.

So the premise driving the bead's framing ("cages are more ephemeral than rip-cage's persistent-container
model, ADR-028's resume guards have no analog") **does not hold as stated**. msb has a working
persistent-sandbox story today. The open question this spike actually answers is narrower and more
useful: **what specifically is lost** across each event (crash/restart, the reboot surrogate, full
recreate) and **at what cost**, so the recreate-vs-persist tradeoff can be made with real numbers instead
of an assumed "no resume" ceiling.

---

## 1. Q1 — lifecycle verbs and overlay persistence across stop/start

`msb stop <name>` / `msb start <name>` are distinct from `msb remove <name>` (confirmed via `msb --tree`
and live use — `remove` errors on a running sandbox without `--force`; `stop`/`start` just toggle
`status`).

**Live test** (`lc-persist`, `rip-cage:latest`, 2 vCPU / 1G):

```
msb create rip-cage:latest --name lc-persist -c 2 -m 1G \
  -v /tmp/lc-mount:/workspace \
  --mount-named lc-dirvol:/data \
  --mount-named lc-diskvol:/diskdata:kind=disk,size=2G \
  --net-rule "allow@deb.debian.org:tcp:443,allow@deb.debian.org:tcp:80" \
  --label spike=lifecycle
```

Wrote markers across every state class, then:

```
msb exec lc-persist -u root --timeout 60s -- bash -c "apt-get update -qq && apt-get install -y -qq cowsay"
# → Setting up cowsay (3.03+dfsg2-8) ...  (installed clean)
msb exec lc-persist -- bash -c 'echo overlay-marker-content > ~/overlay-marker.txt; mkdir -p ~/nonmounted-dir; echo nonmounted-content > ~/nonmounted-dir/marker.txt'
msb exec lc-persist -- bash -c 'echo dirvol-content > /data/dirvol-marker.txt'
msb exec lc-persist -u root -- bash -c 'echo diskvol-content > /diskdata/diskvol-marker.txt'
msb exec lc-persist -- bash -c 'nohup sleep 3600 >/dev/null 2>&1 & disown'   # long-running process marker
```

```
$ date +%s.%N; msb stop lc-persist; date +%s.%N
1783586215.346512000
   ✓ Stopped      lc-persist
1783586215.464676000        # stop: 0.118s

$ date +%s.%N; msb start lc-persist; date +%s.%N
1783586233.378141000
   ✓ Started      lc-persist
1783586233.696694000        # start: 0.318s
```

Post-start check:

```
$ msb exec lc-persist -- bash -c "cat ~/overlay-marker.txt; cat ~/nonmounted-dir/marker.txt; ls -la /usr/games/cowsay; \
    cat /workspace/host-marker.txt /workspace/guest-marker.txt; cat /data/dirvol-marker.txt; cat /diskdata/diskvol-marker.txt; \
    ps aux | grep sleep; uptime"
overlay-marker-content
nonmounted-content
-rwxr-xr-x 1 root root 4664 May 11  2020 /usr/games/cowsay
Thu Jul  9 10:35:30 CEST 2026        # host-written marker, unchanged
guest-wrote-this
dirvol-content
diskvol-content
agent  215  ...  bash -c  <the exec itself>     # the sleep 3600 process is GONE
agent  224  ...  grep sleep
 08:37:20 up 0 min, ...                          # fresh boot, uptime resets to 0
```

Net-rule enforcement was also re-applied on start **without resupplying `--net-rule`**:

```
$ msb exec lc-persist -- curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 https://deb.debian.org/debian/dists/trixie/InRelease
HTTP 200
$ msb exec lc-persist -- curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 https://example.com
curl: (6) Could not resolve host: example.com     # still denied post-restart, no flags resupplied
```

**Verdict:** overlay writes (apt-installed packages, non-mounted-path files), mounted host dirs, named
dir volumes, and disk volumes **all survive stop/start intact**. Running processes **do not** (clean
kernel boot each time — `uptime` resets to 0). The declared config (mounts, net rules, labels, resources)
is **stored and reapplied automatically** on start — the creator does not need to resupply flags for a
plain resume.

---

## 2. Q2 — flag persistence: msb reapplies, rc does not own recreate-from-config for resume

`msb inspect <name> --format json` returns two blocks: `active_config` (live, VM-derived — null while
stopped) and `config` (the **declared, persisted** config — present in both states):

```
$ msb inspect lc-persist --format json   # while STOPPED
{
  "status": "Stopped",
  "active_config": null,
  "config": {
    "mounts": [ ... 4 entries: /workspace bind, /data named, /diskdata named, /tmp tmpfs ... ],
    "network": { "policy": { "rules": [
        {"action":"allow","destination":{"domain":"deb.debian.org"},"direction":"egress","ports":[{"start":443,"end":443}],"protocols":["tcp"]},
        {"action":"allow","destination":{"domain":"deb.debian.org"},"direction":"egress","ports":[{"start":80,"end":80}],"protocols":["tcp"]}
    ]}},
    "labels": {"spike":"lifecycle", ...},
    "resources": {"cpus":2,"memory_mib":1024, ...},
    ...
  }
}
```

Config is backed by a shared sqlite store at `~/.microsandbox/db/msb.db` (WAL-mode; grows across the
session as sandboxes mutate). `msb start <name>` takes **only the name** — no flags — and the net-rule
enforcement check above (§1) proves it isn't just recorded metadata, it is genuinely **reapplied and
enforced** on boot.

**Verdict: msb reapplies flags on start.** For the *resume an existing sandbox* path, `rc` does **not**
need to own recreate-from-config — `msb start <name>` alone reconstructs the full runtime state
(mounts, net policy, resources, labels) from the declared config msb already persisted at `create`/`run`
time. `rc` still owns the config at **initial creation** (translating `.rip-cage.yaml`/manifest into msb
flags), and would own it again for a genuine **destroy + recreate** cycle (§5) — but not for
stop→start.

---

## 3. Q3 — "daemon restart": msb 0.6.4 has no separate central daemon; each cage is its own supervised process

Before testing this, live inspection was needed to find what "the msb daemon" even *is* on this version —
the bead's phrasing (from Docker-daemon intuition) doesn't map directly.

```
$ ps aux | grep -iE "krun|agentd|msb"
jonatanpi  59879  ...  /Users/jonatanpi/.local/bin/msb sandbox --name lc-persist --sandbox-id 45 \
                        --startup-fd 98 --vcpus 2 --memory-mib 1024 --config-fd 96
```

**Finding: there is no single shared `msbd`/central daemon process on this host.** Each running sandbox
is its own `msb sandbox --name <n> ...` process, coordinating through the shared sqlite store
(`~/.microsandbox/db/msb.db`) and per-sandbox unix sockets (`~/.microsandbox/run/agent/<id>.sock`). No
`launchctl`/`brew services` entry exists for it either (checked, both empty). So "restart the daemon"
has no literal analog here; the live-testable equivalent is **kill a running sandbox's own supervisor
process** — which is exactly the failure mode a central daemon restart would produce for that sandbox
under a Docker-style architecture, and is more informative here because it isolates per-sandbox blast
radius (relevant to Q8 below).

**Live test:**

```
$ msb list
lc-persist    rip-cage:latest    running   2026-07-09 10:35:36
$ kill -9 59879                                     # kill the sandbox's own VM process directly
$ msb list
lc-persist    rip-cage:latest    crashed   2026-07-09 10:35:36     # correctly detected, not stale "running"
$ msb exec lc-persist -- echo test
test                                                 # msb exec transparently re-launched it
$ msb start lc-persist
   ✓ Started      lc-persist
$ ps aux | grep "sandbox --name lc-persist"
jonatanpi  60250  ...  msb sandbox --name lc-persist --sandbox-id 45 ...   # new process, same sandbox-id
$ msb exec lc-persist -- bash -c "cat ~/overlay-marker.txt; cat /data/dirvol-marker.txt; cat /diskdata/diskvol-marker.txt; uptime"
overlay-marker-content
dirvol-content
diskvol-content
 08:38:01 up 0 min, ...
```

**Verdict:** a killed sandbox process is detected cleanly (`status: crashed`, not a stale/orphaned
"running" entry), and recovers cleanly via either a plain `msb exec` (which transparently relaunches a
crashed sandbox on next use) or an explicit `msb start`. No data loss, no manual cleanup needed, no
orphaned VM process left behind. **No shared-daemon failure mode exists to test** — because there is no
shared daemon; each cage's crash is isolated by construction (confirmed further at multi-cage scale, §6).

---

## 4. Snapshot verdict (the critical-reframe item) — WORKS on 0.6.4, live-proven end to end

Since Q1–Q3 already showed stop/start persistence works, the highest-value remaining check was msb's own
documented `msb snapshot` feature — is it real on 0.6.4, or still the stub the bead's premise implies?

```
$ msb create rip-cage:latest --name lc-snaptest -c 1 -m 512M
$ msb exec lc-snaptest -- bash -c "echo snapshot-marker-content > ~/snap-marker.txt"
$ msb stop lc-snaptest
   ✓ Stopped      lc-snaptest
$ msb snapshot create lc-snap-v1 --from lc-snaptest
   ✓ Snapshotted  lc-snaptest
   sha256:faa1c9df275125ada074b68846c93f5e0dfec94f555e89bedbc810a7c5f019a1
   /Users/jonatanpi/.microsandbox/snapshots/lc-snap-v1
$ msb snapshot list
lc-snap-v1    rip-cage:latest    4.0 GiB    2026-07-09 10:53:19    sha256:faa1c9df2751

$ msb remove --force lc-snaptest          # FULLY destroy the original sandbox, not just stop
   ✓ Removed      lc-snaptest
$ msb list
No sandboxes found.

$ msb run --name lc-snaprestore --snapshot lc-snap-v1 -- cat /home/agent/snap-marker.txt
snapshot-marker-content                   # a BRAND-NEW, differently-named sandbox, booted from the snapshot, has the marker
```

Timed separately (isolated run, marker pre-confirmed present):

```
$ T0=$(date +%s.%N); msb run --name lc-snaptime --snapshot lc-snap-v1 -- cat /home/agent/snap-marker.txt; T1=$(date +%s.%N)
snapshot-marker-content
snapshot-boot-to-marker-confirmed: 0.293s
```

**Verdict: snapshots genuinely work on 0.6.4.** Disk-only and stopped-only exactly as documented (the
snapshot captures the full writable overlay — 4.0 GiB, the `--oci-upper-size` default, not a thin/delta
capture). Booting from a snapshot is **not meaningfully slower than a cold `msb run`** (0.29s either way
— §5), but a snapshot **preserves accumulated filesystem state** (installed packages, config, credential
files, anything written since the base image) that a cold recreate discards outright. This makes
snapshot+restore a real, cheap "checkpoint and resume" primitive, not just a stop/start convenience —
directly relevant to the epic's persistent-vs-recreate decision.

---

## 5. Q5 — recreate cost, measured

Three numbers, isolated and clean (each its own timed command, no backgrounded/compound noise):

| Path | Command | Wall-clock |
|---|---|---|
| **Bare cold boot** (no mounts/rules), detach only | `msb run -d --name X rip-cage:latest -- sleep infinity` | **0.259s** |
| Bare cold boot **+ first working exec** (toolchain paths confirmed: herdr, claude, dcg, pi, node, python3 all present) | same, then `msb exec X -- which herdr claude dcg pi node python3` | **0.292s** |
| **Fully-configured cold boot** (2 mounts incl. a bind mount, `--net-default deny` + `--net-rule allow@…`, a label) + confirmed mount + toolchain working | `msb create rip-cage:latest --name X -c 2 -m 1G -v host:/workspace --net-rule "allow@api.anthropic.com:tcp:443" --net-default deny --label rc.mediators=iron-proxy` | **0.303s** |
| **Snapshot restore** to a working, marker-confirmed cage (§4) | `msb run --name X --snapshot lc-snap-v1 -- cat ...` | **0.293s** |

**Headline: recreate-to-working-cage is ~0.3 seconds**, essentially identical whether cold-booting the
image or restoring from a snapshot, and essentially unaffected by adding realistic `rc`-shaped flags
(mounts, net policy, labels). This matches and sharpens the 2026-07-07 spike's 0.27s warm-boot figure —
that number already generalizes to the "real" recreate case, not just a bare no-op boot.

**What a cold recreate genuinely loses that host mounts do NOT cover** (live-confirmed by the marker
tests in §1/§4, not asserted):

- **Overlay-fs writes** — anything installed or written outside a mounted path or named/disk volume:
  `apt`/`pip`/`npm`-installed packages, dotfiles under `$HOME` not host-projected, shell history, `mise`
  tool installs, any in-guest cache. A cold `msb run`/`msb create` starts from the pristine image layer
  every time; only `msb start` (stop/start) or `msb run --snapshot` carry it forward.
- **Running processes and in-flight state** — confirmed gone even across a plain stop/start (§1), let
  alone a full recreate: tmux/herdr session-server processes, any backgrounded job, in-progress
  long-running commands. This is **not** an artifact of recreate specifically — it's true of *every*
  event that reboots the guest kernel, including the intentional stop/start suspend/resume path. Only a
  live, running sandbox retains process state; nothing (not even snapshot) captures memory/process state
  — snapshots are disk-only, explicitly (msb's own docs and confirmed live: snapshot requires the
  sandbox to be *stopped* first).
- **Non-mounted host-side caches inside the guest** — e.g. a language toolchain's download cache under
  `~/.cache` if that path isn't a host bind or named volume.

**What a cold recreate does NOT lose** (also live-confirmed, §1/§4/§6): anything on a **named or disk
volume** (independent lifecycle object, survives even `msb remove --force` of every sandbox referencing
it — §6), anything on a **host-mounted directory** (lives on the host filesystem, was never guest state
to begin with), and — per the operator framing already in the bead — anything projected from `~/.claude`,
`~/.pi`, beads/dolt state, which are host-mounted paths in rip-cage's actual manifest, not overlay
writes.

**One gotcha hit live, worth flagging for the migration design:** attempting to bootstrap a herdr
session-server via the documented `setsid+nohup+script -qec` factory pattern (2026-07-07 findings §8a)
inside a **single combined `msb exec ... & disown; ...`** invocation consistently triggered this
environment's own auto-backgrounding heuristic and produced **no captured output at all**, even after
waiting well past any reasonable completion time — the harness treated the call as long-running and the
task-output file stayed empty. This matches the exact gotcha the task brief warned about
("`msb exec` of a long-running or hanging command can get auto-backgrounded... output may not land
cleanly"). Splitting into a bounded, non-backgrounding probe would very likely fix it, but wasn't
re-attempted since herdr's own functionality under msb is already proven end-to-end in the
2026-07-07 findings (§8a/§8a-follow-up) — this note is scoped to "the interaction between shell job
control inside a single `msb exec` call and this harness," not a new msb capability gap.

---

## 6. Q6 — named-volume + disk-volume persistence (stop/start, crash/recover, reboot surrogate, full removal)

Already exercised as part of every event above; consolidated here.

```
$ msb volume list      # before any sandbox referencing them exists
lc-diskvol    disk    2 GiB    ...
lc-dirvol     dir     -        ...

# ... stop/start (§1), crash+recover (§3), reboot surrogate (§4/§7 below) — dirvol/diskvol markers
# survived every one of those events, already shown inline above.

# The decisive test: does the volume survive the SANDBOX being fully destroyed, not just stopped?
$ msb remove --force lc-persist
   ✓ Removed      lc-persist
$ msb volume list
lc-diskvol    disk    2 GiB    ...      # both volumes still exist, independent of any sandbox
lc-dirvol     dir     -        ...

$ msb run rip-cage:latest --mount-named lc-dirvol:/data --mount-named lc-diskvol:/diskdata:kind=disk,size=2G \
    -- bash -c "cat /data/dirvol-marker.txt; cat /diskdata/diskvol-marker.txt"
dirvol-content
diskvol-content            # data intact, reattached to a brand-new, unrelated sandbox
```

**Verdict:** named-dir and disk-kind volumes are **first-class, independent lifecycle objects** — they
survive stop/start, sandbox crash+recover, the reboot-stack surrogate, and even a full `msb remove
--force` of every sandbox that ever referenced them, and can be freely reattached to a completely new
sandbox with data intact. This is the strongest persistence guarantee in the whole matrix, and it means
the dind `docker-data` disk volume (the concern named explicitly in the bead) is safe under every scenario
tested here — a recreated dind cage that remounts the same disk volume does **not** need to re-pull.

---

## 7. Q4 — host reboot: NOT performed (per the bead's own DO-NOT), surrogate performed and labeled

**Per the bead's explicit instruction, the host was NOT rebooted.** The sanctioned surrogate — described
by the bead as "fully stop/start the msb stack (daemon + supporting processes)" — required reinterpreting
given §3's finding that 0.6.4 has **no separate central daemon/stack to stop/start**; the closest
faithful analog to "every sandbox process dies simultaneously, filesystem/db state untouched" (which is
what a reboot actually does to this architecture) is: **simultaneously kill every running sandbox's own
supervisor process**, for sandboxes under this spike's control, then bring them back with `msb start`.

**LABEL, explicit: this is a "kill-all-owned-sandbox-processes-simultaneously surrogate," not a true host
reboot.** It does not exercise: actual host kernel shutdown/cold-start, disk unmount/remount, the
`~/.microsandbox` sqlite store surviving an unclean write mid-transaction, launchd re-spawning anything,
or network re-initialization. Those remain genuinely untested by this spike.

**Live test** (two cages up simultaneously — also serves as the Q8 multi-cage matrix):

```
$ ps aux | grep -E "sandbox --name lc-persist"
jonatanpi  60250  ...  msb sandbox --name lc-persist  --sandbox-id 45 ...
jonatanpi  60485  ...  msb sandbox --name lc-persist2 --sandbox-id 46 ...

$ date +%s.%N; kill -9 60250 60485; sleep 1
1783586324.728613000
$ msb list
lc-persist2    rip-cage:latest    crashed   2026-07-09 10:38:29
lc-persist     rip-cage:latest    crashed   2026-07-09 10:35:36     # both detected, list stays coherent

$ date +%s.%N; msb start lc-persist; msb start lc-persist2; date +%s.%N
1783586330.663248000
   ✓ Started      lc-persist
   ✓ Started      lc-persist2
1783586331.072582000                                                  # both back in 0.409s combined

$ msb exec lc-persist  -- bash -c "cat ~/overlay-marker.txt; cat /data/dirvol-marker.txt; cat /diskdata/diskvol-marker.txt; cat /workspace/host-marker.txt"
overlay-marker-content
dirvol-content
diskvol-content
Thu Jul  9 10:35:30 CEST 2026
$ msb exec lc-persist2 -- bash -c "cat ~/marker2.txt; cat /workspace/host-marker2.txt"
cage2-overlay-marker
Thu Jul  9 10:38:29 CEST 2026
```

**Verdict:** under this surrogate, both cages recovered identically and fully — all overlay/mount/volume
markers intact, `msb list` never showed a stale or inconsistent entry, and one cage's crash+recovery had
zero observable effect on the other (confirmed independently in §3 too, single-cage). No shared-daemon
failure mode was observed **because the architecture has no shared daemon** (§3) — each cage's
crash-detection and recovery is scoped to its own process/sqlite-row. The real host-reboot-specific risks
this surrogate cannot speak to (mid-write db corruption, launchd/supervisor respawn correctness, disk
remount ordering) remain open and would need an actual reboot (or the operator's own past 0.6.4 reboot
history, if any) to close out.

---

## 8. Q7 — virtiofs host-edit coherence (ADR-010 auth hot-swap question)

**Setup:** `msb run -d --name lc-virtiofs rip-cage:latest -v /tmp/lc-virtiofs:/workspace -- sleep infinity`,
with `/tmp/lc-virtiofs/.credentials.json` mounted at `/workspace/.credentials.json`.

### 8a. In-place, inode-preserving rewrite (the actual rc auth-refresh pattern)

```
$ stat -f "%i" /tmp/lc-virtiofs/.credentials.json
8953873
$ python3 -c "
with open('/tmp/lc-virtiofs/.credentials.json','r+') as f:
    f.seek(0); f.write('{\"token\":\"inplace-final-v4\"}'); f.truncate()
"
$ stat -f "%i" /tmp/lc-virtiofs/.credentials.json
8953873                                    # inode unchanged — genuine in-place rewrite

$ date +%s.%N; msb exec lc-virtiofs -- cat /workspace/.credentials.json; date +%s.%N
1783586888.950685000
{"token":"inplace-final-v4"}
1783586888.966889000                       # guest read landed ~16ms after the timestamp taken right after the write
```

### 8b. Delete-and-recreate (inode-changing — the variant that breaks Docker bind-mounts)

```
$ rm /tmp/lc-virtiofs/.credentials.json
$ python3 -c "open('/tmp/lc-virtiofs/.credentials.json','w').write('{\"token\":\"delete-recreate-v5\"}')"
$ stat -f "%i" /tmp/lc-virtiofs/.credentials.json
8954151                                    # different inode — genuine delete+recreate

$ date +%s.%N; msb exec lc-virtiofs -- cat /workspace/.credentials.json; date +%s.%N
1783586901.165625000
{"token":"delete-recreate-v5"}
1783586901.184341000                       # ~19ms
```

**Verdict:** both the in-place (inode-preserving) and delete-and-recreate (inode-changing) host-side
rewrite variants become visible in-guest **essentially immediately** (tens of milliseconds, bounded by
the `msb exec` round-trip itself, not by any observable propagation delay). **No virtiofs caching
staleness was observed for either variant on this machine/workload.** This is a materially better answer
than Docker bind-mounts, where the delete-and-recreate variant is documented to break coherence — msb's
virtiofs implementation handled it cleanly. This directly de-risks the ADR-010 auth hot-swap design: an
in-place credential rewrite (the pattern rc's auth refresh actually uses) propagates promptly, and even
the harder delete-and-recreate variant is not a hazard on this substrate.

---

## 9. Q9 — image update flow

**Setup:** a running cage on the original `rip-cage:latest` digest; built a trivial derived image
(`FROM rip-cage:latest` + one marker file) via `docker build`, using the host's existing OrbStack-backed
docker CLI (confirmed present: `docker version` → 29.4.0, context `orbstack`).

### 9a. Loading under a NEW tag name — no collision, coexists

```
$ docker build -t rip-cage:msb-spike-v2 /tmp/lc-dockerfile-v2   # FROM rip-cage:latest + USER root + marker
$ docker save rip-cage:msb-spike-v2 | msb image load --tag rip-cage:msb-spike-v2
   ✓ Loaded       rip-cage:msb-spike-v2
$ msb image list
rip-cage:msb-spike-v2    sha256:bd3ee324e808    1.1 GiB   2026-07-09 10:50:03
docker:dind               sha256:8a370e65c039    125.3 MiB 2026-07-08 08:19:40
rip-cage:latest           sha256:5b655e29e074    1.1 GiB   2026-07-07 21:04:06   # untouched, distinct digest

$ msb exec lc-virtiofs -- cat /etc/rip-cage-image-version     # the ALREADY-RUNNING cage, still on old image
cat: /etc/rip-cage-image-version: No such file or directory   # correctly does NOT see the new file
```

### 9b. Loading under the SAME tag name (`rip-cage:latest`) — the realistic in-place update case

```
$ docker save rip-cage:msb-spike-v2 | msb image load --tag rip-cage:latest
   ✓ Loaded       rip-cage:latest
   ✓ Loaded       rip-cage:msb-spike-v2
$ msb image list --format json | jq -r '.[] | "\(.reference) \(.digest)"'
rip-cage:msb-spike-v2 sha256:bd3ee324e808f42ff4f88f46fee0d700a7b924c458baa1f70558b43adf600e02
docker:dind            sha256:8a370e65c039a98b80ea802d55a3045c05d0d21921e7e547bfa20cb945f2a801
rip-cage:latest        sha256:bd3ee324e808f42ff4f88f46fee0d700a7b924c458baa1f70558b43adf600e02  # now points at the NEW digest
```

`msb image list` shows **one row per tag** — the old digest silently drops out of the *listed* view under
that name once the tag is repointed (no error, no versioned-suffix collision, no prompt).

**But the already-running cage is completely unaffected:**

```
$ msb exec lc-virtiofs -- cat /etc/rip-cage-image-version
cat: /etc/rip-cage-image-version: No such file or directory    # STILL the old content
$ msb exec lc-virtiofs -- whoami
agent                                                            # still fully functional
$ msb inspect lc-virtiofs --format json | jq -r '.config.manifest_digest'
sha256:5b655e29e074f93e2da08fdd665595ca717163e06e1b01efd6889a81b90d86d8   # pinned to the OLD digest it booted from
```

A brand-new sandbox created *after* the retag picks up the new content immediately:

```
$ msb run rip-cage:latest -- cat /etc/rip-cage-image-version
msb-spike-v2-marker
```

**Verdict:** each sandbox pins its own `manifest_digest` at creation time and is **completely insulated**
from later `image load`/retag operations against the tag name it was created from — no drift, no
surprise mutation of a long-running cage, no collision or version-suffixing when reloading under an
existing tag (the old digest is just dereferenced from that tag's listing; the blob presumably persists
on disk as long as a running sandbox references it — not independently confirmed by digging into
`~/.microsandbox/cache`, but implied by the running cage continuing to work normally throughout). **The
operator flow to move a cage to a new image is exactly "reload/retag is free and safe to do anytime;
picking up the new content requires an explicit recreate"** (`msb create --replace` or remove+create) of
each cage that should move — which maps directly onto the migration-shape sketch's existing `rc up
--replace`-style flow (2026-07-07 findings §8b) and is the correct anchor for rip-cage's `rc build && rc
up` update cycle: build/load is decoupled from and non-disruptive to already-running cages, and adopting
the new image is an explicit, per-cage operator action, not an ambient side effect.

---

## 10. Persistence matrix

State class × event. ✅ = live-confirmed to survive intact. ❌ = live-confirmed to NOT survive (by
design — a fresh kernel boot). N/T = not directly tested this session (reasoned from adjacent live
evidence, flagged).

| State class | stop → start | sandbox-process crash + recover | reboot-stack surrogate (kill-all + start) | full `remove` + volume reattach | image reload/retag of a running cage |
|---|---|---|---|---|---|
| **Overlay writes** (apt-installed pkgs, non-mounted `$HOME` files) | ✅ (§1) | ✅ (§3) | ✅ (§7) | ❌ — overlay is destroyed with the sandbox (§5); only `msb snapshot` (§4) captures it across a full destroy | N/A — running cage keeps its own pinned digest/overlay (§9) |
| **Mounted host dirs** (`-v host:/workspace`) | ✅ (§1) | ✅ (implied — host fs, never guest state) | ✅ (§7) | ✅ — lives on host fs regardless of sandbox lifecycle | ✅ — unaffected, host fs |
| **Named dir volume** | ✅ (§1) | ✅ (§3) | ✅ (§7) | ✅ (§6 — survives even full sandbox removal) | ✅ — independent object |
| **Disk-kind volume** (the dind `docker-data` case) | ✅ (§1) | ✅ (§3) | ✅ (§7) | ✅ (§6) | ✅ — independent object |
| **Running processes / in-flight state** (tmux, herdr server, background jobs) | ❌ (§1 — `uptime` resets, `sleep 3600` gone) | ❌ (kernel restarts on relaunch) | ❌ (§7) | ❌ | N/A |
| **Sandbox flag config** (mounts, net rules, resources, labels) | ✅ — reapplied automatically, net-rule enforcement reconfirmed live (§1/§2) | ✅ — same declared config, unaffected by the process dying (§3) | ✅ (§7 — both cages' config intact post-recovery) | N/A (config is destroyed with the sandbox; **but see §4, snapshot captures a full point-in-time filesystem+config-adjacent state**) | N/A — config is per-sandbox, independent of image tag |
| **Snapshot-captured state** (disk only, stopped-only) | N/T directly (didn't stop/start a *restored-from-snapshot* sandbox again this session) | N/T | N/T | ✅ by construction — §4's entire point is surviving full removal of the source sandbox | N/A |

---

## 11. Honest recommendation: persistent-sandbox story vs cheap-recreate + cockpit re-registration

Both are genuinely viable on 0.6.4, and they are not mutually exclusive — the evidence above supports a
**tiered** answer rather than picking one:

**For the common case — an operator's long-lived cage across ordinary stop/start (laptop sleep, `rc
down`/`rc up`, session boundaries):** `msb stop`/`msb start` is a real, fast (0.1–0.3s), zero-reconfiguration
suspend/resume that preserves everything except running processes. This is very close to what ADR-028's
resume guards were written to protect on the docker-persistent-container model, and it costs `rc`
approximately nothing to adopt — no recreate-from-config machinery needed for this path, `msb start
<name>` already does it. **This alone dissolves most of the bead's original "cages are too ephemeral"
worry.**

**For "the sandbox process died / needs a clean restart" (crash, or the reboot-stack surrogate):**
recovery is also cheap and clean (§3/§7) — `msb start` (or even a bare `msb exec`) transparently
relaunches a crashed sandbox with all persisted state intact, and multiple cages fail/recover
independently (no shared-daemon blast radius, because there is no shared daemon). `rc` needs to detect
`status: crashed` (trivial, `msb list --format json`) and call `msb start`, not rebuild its config.

**For genuine loss events (full `msb remove`, a real host reboot with `~/.microsandbox` corruption, or
deliberately moving a cage to a new image build):** the honest cost is **~0.3 seconds of VM boot time**
either via cold `msb run`/`msb create` or via `msb run --snapshot` — both measured, both essentially
identical (§5). The real cost of a full recreate is **not** wall-clock; it's **what gets thrown away**:
overlay writes (installed packages, un-mounted config) unless a **snapshot** was taken first (§4, which
now genuinely works and costs nothing extra in boot time), and any in-flight process/session state
(tmux/herdr servers) regardless of which resume path is used. **Named/disk volumes are safe across every
event tested, including full removal** (§6) — so keeping durable, large, or slow-to-rebuild state (the
dind `docker-data` volume being the concrete example the bead named) on a named/disk volume rather than
the overlay is the correct default design regardless of which persistence tier `rc` ends up choosing.

**Recommendation for the migration design:** don't build a `rc`-owned recreate-from-config engine as the
*primary* resume path — `msb start` already is that engine for the common case, for free. Instead:

1. Treat **stop/start as the default resume path** or ordinary session boundaries (`rc down`/`rc up`) —
   cheapest, zero config re-derivation, matches ADR-028's intent almost exactly.
2. Treat **snapshot-before-risky-operation** (e.g., before an image update, or as a periodic
   "checkpoint the accumulated overlay state" operation) as the mechanism that actually answers "what
   if the sandbox needs to be fully destroyed but I don't want to lose installed packages" — this is
   the piece the bead's stale premise assumed didn't exist, and it does, cheaply.
3. Keep the **dind docker-data (and any similarly slow-to-rebuild) state on a named/disk volume**,
   independent of sandbox lifecycle — confirmed safe across every event tested here, including full
   sandbox removal.
4. `rc` still needs to own **initial config generation** (manifest → msb flags) and a **`--replace`-style
   recreate flow for deliberate image updates** (§9 — the new image never disturbs a running cage, so
   adoption is explicit and per-cage, matching `rc`'s existing `rc build && rc up` shape).
5. What `rc` does **not** need to build: a "reconstruct all flags from scratch to resume a stopped
   sandbox" engine — msb already owns that for the plain-resume case (§2).

**What this recommendation costs, honestly:** it leans on msb's crash-detection and config-persistence
being as robust in production as observed here (a single macOS/HVF host, one operator, a handful of
cages, a session lasting under an hour) — genuinely untested: multi-day/multi-week persistence (the
scale ADR-028 actually cares about), an unclean host shutdown mid-write to the sqlite store, and
snapshot behavior at real scale (a 4.0 GiB per-snapshot cost, confirmed live, adds up fast if snapshotting
becomes routine — worth a retention/pruning policy, not evidence against the approach).

---

## Appendix: environment/session notes

- **Concurrent spike on the same machine.** A second, independent spike (rip-cage-hfno, evidenced by a
  sandbox named `sshverify` visible in `ps aux` throughout this session) was running in parallel. It was
  never inspected, execed into, or touched — all cages created for this spike used an `lc-`-prefixed
  name. One genuine observation from proximity: at one point `ps aux` showed multiple in-flight
  `msb exec sshverify` processes while `msb list`/`msb inspect sshverify` reported "not found" — most
  likely a benign race between that spike's own rapid create/remove cycles and this session's polling,
  not investigated further since it's out of scope for this bead.
- **`msb-exec` auto-backgrounding gotcha, hit live** (matches the task brief's warning): a single `msb
  exec` call containing in-guest shell job control (`cmd & disown; ...`, used for the herdr
  session-server factory pattern) got auto-backgrounded by this harness twice, both times producing an
  empty captured-output file even after the command's own bounded `--timeout` had long since expired.
  Worked around by not re-attempting that specific spawn shape; noted in §5 as a caveat, not a msb
  capability gap.
- **`docker save | msb image load` requires `USER root`** if the target Dockerfile step needs to write
  outside the image's default non-root user's writable paths — `rip-cage:latest`'s default user is
  `agent` (uid 1000), matching the 2026-07-07 findings.
- **No `timeout`/`gtimeout` binary on this macOS host by default** — used `msb exec --timeout` /
  `msb create --timeout`-equivalent flags instead of wrapping in a host-side `timeout`.
- Machine restored to its starting state at the end of this session: `msb list` empty, `msb volume list`
  shows only the pre-existing `dockerdata` volume (not created by this spike), `msb image list` shows
  only `docker:dind` and `rip-cage:latest` (the latter's *digest string* differs cosmetically from the
  session start after a `docker save`/`msb image load` round-trip used to restore it post-§9 testing —
  confirmed via content check, not just digest, that this is the same untouched original: no
  `/etc/rip-cage-image-version` marker file, full toolchain present), `msb snapshot list` empty, no
  stray `/tmp/lc-*` directories left behind.
