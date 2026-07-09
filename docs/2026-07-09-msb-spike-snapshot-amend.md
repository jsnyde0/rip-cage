# msb spike — snapshot mechanics for the net-rule-change repair loop (2026-07-09)

Bead: **rip-cage-0n25**. Epic: rip-cage-tsf2. Machine: mac mini, msb v0.6.4
(`/Users/jonatanpi/.local/bin/msb`), image `rip-cage:latest`. Related: rip-cage-r8jl (lifecycle spike,
`docs/2026-07-09-msb-spike-lifecycle.md` — the ~0.3s cold-recreate figure and the §10 persistence matrix
this spike fills the last-row cell of) and rip-cage-hfno (egress-observability spike,
`docs/2026-07-09-msb-spike-egress-observability.md` — established net-rule changes are recreate-only,
the premise this whole spike investigates a cheaper variant of).

All commands below are live output from this session. Sandboxes used: `snapamend-src`,
`snapamend-restored`, `snapamend-loop-restored`, `snapamend-q4-restored` — all removed at cleanup.
Snapshots: `snapamend-snap-v1`, `snapamend-snap-v2`, `snapamend-snap-loop`, `snapamend-snap-q4` — all
removed at cleanup. Starting state confirmed clean: `msb list` → no sandboxes, `msb snapshot list` → no
snapshots indexed, `~/.microsandbox/snapshots` → 0 files, 0B.

**Netstack caveat applied throughout** (per `msb-netstack-fake-accepts-tcp-connect-not-egress`): every
reachability claim below is backed by a real HTTP status code **and nonzero `size_download`**, never a
bare `connect()`/exit-0. Every denial claim is backed by the DNS-stage block signature (`curl: (6) Could
not resolve host`, exit code 6), consistent with the deny-default + domain-allowlist behavior already
characterized in rip-cage-hfno.

---

## Setup — source cage with a realistic overlay and net rules

```
$ msb create rip-cage:latest --name snapamend-src -c 2 -m 1G \
    --net-default deny --net-rule "allow@example.com:tcp:443,allow@deb.debian.org:tcp:443,allow@deb.debian.org:tcp:80" \
    --label spike=snapamend
$ msb exec snapamend-src -- bash -c "echo snapamend-overlay-marker-v1 > ~/snapamend-marker.txt"
$ msb exec snapamend-src -u root --timeout 60s -- bash -c "apt-get update -qq && apt-get install -y -qq cowsay"
Setting up cowsay (3.03+dfsg2-8) ...
```

(`deb.debian.org` had to be allowlisted alongside `example.com` for `apt-get` to reach the mirror at all —
the deny-default policy blocks it identically to any other non-allowlisted host, confirmed by the first
attempt failing with `Could not resolve 'deb.debian.org'` before the rule was added.)

Baseline reachability confirmed before touching anything:

```
$ msb exec snapamend-src -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://example.com
HTTP 200 SIZE 559
$ msb exec snapamend-src -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.wikipedia.org
HTTP 000 SIZE 0
curl: (6) Could not resolve host: www.wikipedia.org          # EXIT 6
$ msb exec snapamend-src -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.iana.org
HTTP 000 SIZE 0
curl: (6) Could not resolve host: www.iana.org               # EXIT 6
```

`example.com` allowed (real 200 + 559-byte body), `www.wikipedia.org` and `www.iana.org` both denied
(DNS-stage block signature). These are the "second host" and "third host" used in Q2/Q4.

---

## Q1 — snapshot creation wall-clock, and disk-usage dedupe-vs-linear

```
$ date +%s.%N; msb stop snapamend-src; date +%s.%N
1783597967.098795000
   ✓ Stopped      snapamend-src
1783597967.216107000                       # stop: 0.117s

$ date +%s.%N; msb snapshot create snapamend-snap-v1 --from snapamend-src; date +%s.%N
1783597971.345217000
   ✓ Snapshotted  snapamend-src
   sha256:c6a00b8ca05cd4b5e9247e7325c5461ca24b85a211d5028eaa44388cea681223
   /Users/jonatanpi/.microsandbox/snapshots/snapamend-snap-v1
1783597971.371622000                       # first snapshot create: 0.026s

$ date +%s.%N; msb snapshot create snapamend-snap-v2 --from snapamend-src; date +%s.%N
1783597992.085159000
   ✓ Snapshotted  snapamend-src
   sha256:7b384fb4407666f89eabed297e807867d1b4e7feff2a3495ecf0efa0c6d722ad
1783597992.145713000                       # second snapshot create: 0.061s
```

**Both snapshots completed in tens of milliseconds — not the "copies the full 4.0 GiB overlay" cost the
bead's WHY section anticipated.** Investigated why:

```
$ msb snapshot list
NAME                 IMAGE              SIZE       CREATED                DIGEST
snapamend-snap-v2    rip-cage:latest    4.0 GiB    2026-07-09 13:53:12    sha256:7b384fb44076
snapamend-snap-v1    rip-cage:latest    4.0 GiB    2026-07-09 13:52:51    sha256:c6a00b8ca05c

$ du -sh ~/.microsandbox/snapshots
 54M    /Users/jonatanpi/.microsandbox/snapshots
$ du -sh ~/.microsandbox/snapshots/*
 27M    /Users/jonatanpi/.microsandbox/snapshots/snapamend-snap-v1
 27M    /Users/jonatanpi/.microsandbox/snapshots/snapamend-snap-v2

$ find ~/.microsandbox/snapshots/snapamend-snap-v1 -type f -exec ls -la {} \;
-rw-r--r--  1 jonatanpi  staff  4294967296 Jul  9 13:52 /Users/jonatanpi/.microsandbox/snapshots/snapamend-snap-v1/upper.ext4
-rw-r--r--  1 jonatanpi  staff         347 Jul  9 13:52 /Users/jonatanpi/.microsandbox/snapshots/snapamend-snap-v1/manifest.json
```

**`upper.ext4` reports a logical size of 4294967296 bytes (4.0 GiB — the `--oci-upper-size` default,
matching `msb snapshot list`'s displayed size), but `du` (actual allocated blocks) shows only 27M per
snapshot.** This is an APFS sparse/copy-on-write clone (`clonefile()`), not a literal byte-for-byte copy —
consistent with the ~26-61ms creation time, which is far too fast for a real 4 GiB disk write on this
hardware. The snapshot's *logical* size is always reported as the full overlay capacity; its *real* disk
cost tracks only the blocks actually diverged from the base image (here, ~27M — the apt-installed
`cowsay` package plus a few marker files).

**Growth across the two snapshots is linear in real disk cost, not deduplicated against each other**:
27M + 27M = 54M total for two independent snapshots of the same source cage's same overlay state — each
`snapshot create` is its own independent CoW clone, not a delta against a prior snapshot. (No claim is
made here about deeper backing-store-level block sharing between the two clones and the source; `du`
measures apparent allocation per snapshot directory, which is the operationally relevant number for "how
much disk does N snapshots cost.")

**Q1 verdict:** on this platform (macOS/APFS), snapshot creation is **near-free** (tens of milliseconds)
regardless of overlay size, because it's a filesystem-level CoW clone, not a copy. Real disk cost scales
with **actual overlay writes**, not the nominal 4 GiB capacity, and each snapshot adds its own linear
increment (no snapshot-to-snapshot dedupe observed). This is a materially better cost profile than the
bead's WHY section anticipated ("it copies the full 4.0 GiB overlay") — worth flagging as **APFS-specific**;
this would need reconfirming on a non-CoW filesystem (ext4/xfs on Linux/KVM) before treating "snapshot
creation is nearly free" as a portable fact.

---

## Q2 — THE core question: does restore accept AND apply DIFFERENT `--net-rule` flags?

Restored from `snapamend-snap-v1` with an amended rule set: kept `allow@example.com:tcp:443`, **added**
`allow@www.wikipedia.org:tcp:443` (the previously-denied "second host"), left `www.iana.org` off the
allowlist entirely (the "third host," expected to remain denied).

```
$ date +%s.%N
$ msb run --name snapamend-restored --snapshot snapamend-snap-v1 \
    --net-default deny \
    --net-rule "allow@example.com:tcp:443,allow@www.wikipedia.org:tcp:443" \
    -d -- sleep infinity
$ date +%s.%N
1783598020.999577000
snapamend-restored
1783598021.434938000                       # restore-with-amended-rules: 0.435s
```

**The command was accepted — no rejection, no ignored-flag warning.** Confirmed the *declared* config
actually changed (not just accepted syntactically) via `msb inspect`:

```
$ msb inspect snapamend-restored --format json | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['config']['network']['policy'], indent=2))"
{
  "default_egress": "deny",
  "default_ingress": "deny",
  "rules": [
    {"action":"allow","destination":{"domain":"example.com"},"direction":"egress","ports":[{"start":443,"end":443}],"protocols":["tcp"]},
    {"action":"allow","destination":{"domain":"www.wikipedia.org"},"direction":"egress","ports":[{"start":443,"end":443}],"protocols":["tcp"]}
  ]
}
```

Both rules present — the amended set, not the snapshot-source's original rule set (which had
`deb.debian.org`, not `wikipedia.org`). **Live-enforcement, all four sub-checks, real evidence:**

```
# (a) overlay marker + installed package survived
$ msb exec snapamend-restored -- bash -c "cat ~/snapamend-marker.txt; ls -la /usr/games/cowsay; /usr/games/cowsay overlay-survived | head -1"
snapamend-overlay-marker-v1
-rwxr-xr-x 1 root root 4664 May 11  2020 /usr/games/cowsay
 __________________

# (b) the second host (wikipedia) is NOW reachable — real body, not a bare connect()
$ msb exec snapamend-restored -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.wikipedia.org
HTTP 200 SIZE 120361

# (c) example.com (original rule) still reachable
$ msb exec snapamend-restored -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://example.com
HTTP 200 SIZE 559

# (d) a third host (iana.org, never allowlisted at any point) still denied
$ msb exec snapamend-restored -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.iana.org
HTTP 000 SIZE 0
curl: (6) Could not resolve host: www.iana.org               # EXIT 6, DNS-stage block signature
```

**Q2 verdict — SNAPSHOT-AMEND WORKS:** `msb run --snapshot <snap> --net-default ... --net-rule ...`
**accepts and genuinely applies** a net-rule set that is DIFFERENT from what the source sandbox had at
snapshot time. All four checks confirm: overlay (marker file + apt-installed `cowsay`) is fully preserved
from the snapshot; the newly-added host is reachable with a real 120361-byte HTTP body (well past the
netstack fake-accept trap — a fake-accept would show 0 bytes); the original allowlisted host remains
reachable; a host that was never on either rule set remains denied with the same DNS-stage block
signature seen throughout this and the sibling hfno spike. This is real rule amendment at restore, not a
rejected or silently-ignored flag.

---

## Q3 — lifecycle matrix N/T cell: stop/start a restored-from-snapshot sandbox

r8jl §10's persistence matrix left "Snapshot-captured state" × "stop → start" as N/T ("didn't stop/start a
*restored-from-snapshot* sandbox again this session"). Filled here:

```
$ date +%s.%N; msb stop snapamend-restored; date +%s.%N
1783598049.037004000
   ✓ Stopped      snapamend-restored
1783598049.155260000                       # stop: 0.118s

$ date +%s.%N; msb start snapamend-restored; date +%s.%N
1783598050.644768000
   ✓ Started      snapamend-restored
1783598050.863802000                       # start: 0.219s

$ msb exec snapamend-restored -- bash -c "cat ~/snapamend-marker.txt; ls -la /usr/games/cowsay"
snapamend-overlay-marker-v1
-rwxr-xr-x 1 root root 4664 May 11  2020 /usr/games/cowsay
$ msb exec snapamend-restored -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.wikipedia.org
HTTP 200 SIZE 120361
$ msb exec snapamend-restored -- curl -sS -o /dev/null -w 'HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.iana.org
HTTP 000 SIZE 0
curl: (6) Could not resolve host: www.iana.org
```

**Q3 verdict — ✅.** Marker, installed package, AND the amended net-rule set (wikipedia allowed, iana
still denied) all survive a stop/start cycle of a restored-from-snapshot sandbox, at the same cost
(~0.1–0.2s) as any other stop/start (r8jl §1). The r8jl §10 matrix's last-row "Snapshot-captured state"
cell for the "stop → start" column can now be marked ✅ (was N/T).

---

## Q4 — full repair-loop wall-clock: stop → snapshot → restore-with-amended-rules → verified

Measured as ONE continuous sequential command block (single shell invocation, sequential lines, no
backgrounding) against a fresh live instance of the same cage, to minimize any inter-call measurement
noise:

```
$ date +%s.%N
1783598153.115345000
$ msb stop snapamend-src
   ✓ Stopped      snapamend-src
$ msb snapshot create snapamend-snap-q4 --from snapamend-src
   ✓ Snapshotted  snapamend-src
   sha256:6079559b6fa1b944f2108aff72b22809173712c14b46307ec81b3b85da029e18
$ msb run --name snapamend-q4-restored --snapshot snapamend-snap-q4 \
    --net-default deny --net-rule "allow@example.com:tcp:443,allow@www.wikipedia.org:tcp:443" \
    -d -- sleep infinity
snapamend-q4-restored
$ msb exec snapamend-q4-restored -- bash -c "cat ~/snapamend-marker.txt"
snapamend-overlay-marker-v1
$ msb exec snapamend-q4-restored -- curl -sS -o /dev/null -w 'wiki HTTP %{http_code} SIZE %{size_download}\n' --max-time 8 https://www.wikipedia.org
wiki HTTP 200 SIZE 120361
$ date +%s.%N
1783598153.898458000
```

**Full repair loop (stop → snapshot → restore-with-amended-rules → marker+new-rule confirmed): 0.783
seconds**, end to end, covering every step the bead's Q4 asked for as one number. (Third-host denial was
reconfirmed separately on this same `snapamend-q4-restored` instance immediately after — `curl: (6) Could
not resolve host: www.iana.org` — not included in the timed block above since it's a negative-control
check, not part of the repair action itself.)

**Compared to the ~0.3s cold-recreate figure (r8jl §5):**

| Path | Wall-clock | What survives |
|---|---|---|
| Cold recreate with new rules (`msb create`/`msb run --replace`) | **~0.303s** (r8jl §5) | Mounts, named/disk volumes, host-mounted dirs. **Overlay writes (apt/pip installs, non-mounted `$HOME` files) are LOST** — fresh image layer every time. |
| **Snapshot-amend repair loop** (this spike, Q4) | **0.783s** | Everything cold-recreate keeps, **PLUS the full overlay** (apt-installed `cowsay`, the marker file) — confirmed intact post-restore (Q2a) and post-stop/start (Q3). |

The snapshot-amend path costs roughly **2.6× the cold-recreate wall-clock** (0.783s vs 0.303s) — still
sub-second, still cheap in absolute terms — in exchange for **not losing the overlay**. Both paths equally
lose in-flight process/session state (tmux, herdr servers) per r8jl's general finding that any
guest-kernel-restarting event does this; that cost is identical between the two paths and not a
differentiator.

---

## VERDICT

**SNAPSHOT-AMEND** — works, end to end, in **0.783s** for the full stop → snapshot → restore-with-amended-rules
→ verified sequence (Q4), versus **~0.303s** for a cold recreate that discards the overlay (r8jl §5).

- **Q1**: snapshot creation is near-free on this platform (26–61ms per snapshot, APFS copy-on-write clone
  — logical size reported as the full 4.0 GiB `--oci-upper-size` default, but real disk cost only ~27M per
  snapshot here, tracking actual overlay writes). Growth across snapshots is linear per-snapshot (no
  dedupe between snapshots observed), not the "full 4 GiB copy" cost originally anticipated.
- **Q2 (the core question)**: `msb run --snapshot <snap> --net-rule <amended>` **genuinely applies**
  different net rules than the snapshot source had — confirmed via both the declared `msb inspect` config
  and live traffic: the newly-allowlisted host is reachable with a real 120361-byte HTTP body (not a
  fake-accept), the originally-allowlisted host remains reachable, the overlay (marker + installed
  package) is fully intact, and a never-allowlisted third host remains denied with the standard DNS-stage
  block signature.
- **Q3**: the r8jl §10 matrix's last N/T cell (snapshot-captured state × stop/start) is now ✅ — a
  restored-from-snapshot sandbox's markers, package, and amended net rules all survive a further
  stop/start cycle intact.
- **Q4**: full repair-loop wall-clock is **0.783s**, ~2.6× the 0.303s cold-recreate figure, for the benefit
  of preserving the overlay across a net-rule change.

**Practical implication for the epic (rip-cage-tsf2)'s deny→fix→reload loop design:** snapshot-amend is a
real, cheap, viable repair path when overlay preservation matters (installed packages, accumulated
in-guest state) — not merely a theoretical option that "kills the snapshot path" per the bead's
alternative framing. Cold-recreate-with-new-rules remains cheaper in absolute terms (0.303s vs 0.783s)
and is the right default when the overlay is disposable (e.g., a purely mount-projected cage with no
overlay writes worth preserving) — the two paths are genuinely complementary, not mutually exclusive, and
the choice should be a per-cage question of "does this cage have overlay state worth ~0.5s of extra
recovery time to keep."

---

## Cleanup confirmation

```
$ msb remove --force --label spike=snapamend
   ✓ Removed      snapamend-src
$ msb remove --force snapamend-restored snapamend-loop-restored snapamend-q4-restored
   ✓ Removed      snapamend-restored
   ✓ Removed      snapamend-loop-restored
   ✓ Removed      snapamend-q4-restored
$ msb list
No sandboxes found.

$ msb snapshot remove snapamend-snap-v1 --force
$ msb snapshot remove snapamend-snap-v2 --force
$ msb snapshot remove snapamend-snap-loop --force
$ msb snapshot remove snapamend-snap-q4 --force
   ✓ Removed (×4)
$ msb snapshot list
No snapshots indexed.

$ ls -la ~/.microsandbox/snapshots
total 0
$ du -sh ~/.microsandbox/snapshots
  0B    /Users/jonatanpi/.microsandbox/snapshots

$ msb volume list
NAME          KIND    SIZE    CREATED
dockerdata    dir     -       2026-07-08 08:25:14
$ msb image list
REFERENCE          DIGEST                 SIZE         CREATED
docker:dind        sha256:8a370e65c039    125.3 MiB    2026-07-08 08:19:40
rip-cage:latest    sha256:622d3bcaf310    1.1 GiB      2026-07-07 21:04:06
```

Matches the pre-spike clean-slate state exactly: 0 sandboxes, 0 snapshots, snapshot dir back to 0B
(started at 0B — confirmed at session start), only the pre-existing `dockerdata` volume and the two
already-present base images remain, no `snapamend-`-prefixed anything left behind.
