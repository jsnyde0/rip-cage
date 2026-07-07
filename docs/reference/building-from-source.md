# Building a Tool from Source (the generic builder stage)

This walkthrough covers **ADR-005 D11 mechanism 1** (FLEXIBLE): the single generic from-source builder stage that lets a TOOL manifest entry compile a binary at `rc build` when no prebuilt release exists for the cage's architecture. Prefer prebuilt binaries when they exist ([ADR-005 D6](../decisions/ADR-005-ecosystem-tools.md); see [adding-a-tool.md](adding-a-tool.md)) — from-source is the fallback, most commonly hit on linux-arm64 (Apple Silicon hosts), where many upstreams publish no release.

**ADR-005 D12 (FIRM):** rip-cage supports no *specific* tool's build. The mechanism is one generic stage parameterized entirely by your manifest entry; the per-tool build intelligence lives in **your build script**, which `rc` copies and runs but never interprets. DCG is referenced below as the live instance in this repo — it is a composable recipe, not a blessed tool.

---

## The `build_source` manifest shape

A from-source TOOL entry replaces `install_cmd` with a `build_source` block. The two are **mutually exclusive**, and both are forbidden when `version_pin: "bundled"`:

```yaml
# ~/.config/rip-cage/tools.yaml
version: 1
tools:
  - name: my-tool
    archetype: TOOL
    version_pin: "v1.2.3"          # pin the tag your build script checks out (ADR-005 D3)
    egress: []                      # runtime egress; build-time fetches happen in the builder stage
    mounts: []
    build_source:
      builder_image: "rust:1-slim-trixie"          # the toolchain image the build runs in
      build_script: "path/relative/to/repo-root.sh" # host-side script, COPY'd into the stage
      output_path: "/usr/local/bin/my-tool"        # the binary the script must produce
```

All three sub-fields are required, single-line (newlines would inject Dockerfile directives — rejected fail-closed), and `build_script` must be a **relative path inside the build context** (repo root): absolute paths and any `../` traversal are rejected by the validator with a named error before Docker can fail opaquely. See [manifest-validator.md](manifest-validator.md) for the exact messages.

The build script carries all the judgment: clone/fetch the pinned source, build for the current platform, place the artifact at `output_path`. rip-cage has no build DSL and adds no flags.

## What `rc build` does with it

The flow, in order (functions named for cross-reference into `rc`):

1. **Strict-parse validation** (`_manifest_validate`) — field shape, mutual-exclusion, single-line, path-traversal checks, fail-closed.
2. **Builder-stage codegen** (`_manifest_generate_source_builder_stages`) — emits one isolated Dockerfile stage per from-source entry, injected *before* the runtime stage:

   ```dockerfile
   FROM <builder_image> AS rc-builder-<name>
   COPY <build_script> /rc-build/build.sh
   RUN sh /rc-build/build.sh
   ```

   The stage name is derived from the entry name (lowercased, non-alphanumerics collapsed to hyphens: `rc-builder-my-tool`). The script is `COPY`'d from the build context — never bind-mounted from the host.
3. **Runtime copy** (`_manifest_generate_extra_dockerfile_steps`) — the runtime stage gets only the artifact: `COPY --from=rc-builder-<name> <output_path> /usr/local/bin/<basename of output_path>`. The toolchain, source tree, and build cache stay in the discarded builder layer (the beads/DCG multi-stage pattern, ADR-002).
4. **Pre-build gate** (`_manifest_check_build_isolation`) — static scan of the generated Dockerfile's `rc-builder-*` stages for host-access vectors (host bind mounts, ssh/secret mounts, `VOLUME`). A violation **refuses the build** before `docker build` runs.
5. **`docker build`** runs the stage. Note the stage targets the *build platform* — no `--platform`/`--target` hardcode — so arm64 and amd64 hosts each produce a native binary (arch-adaptive by construction).
6. **Post-build gate** (`_manifest_check_binary_root_owned`) — stats the installed binary inside the built image and refuses the build if it is not root-owned or is group/other-writable.

Both build entrypoints run the gates — `rc build` (`cmd_build`) and the `rc up` auto-build path (`_pull_or_build_local`). That entrypoint-completeness is a FIRM clause of D11: a build path without the validators would be a silent bypass (it happened once — rip-cage-buuo.6 — and is now welded shut).

## Honest limits (read before trusting a third-party build script)

From ADR-005 D11's named residual risk:

- **Stage isolation is filesystem isolation, not network isolation.** A Docker `RUN` in the builder stage reaches the internet by default. A malicious build script could exfiltrate *during* the build while still producing a valid root-owned binary — the validator inspects the build's *output* and the Dockerfile's *structure*, not the script's runtime behavior.
- **Human review of the build script is the load-bearing mitigation.** This is exactly why the manifest is host-only and the authoring flow (D11 mechanism 3) produces reviewable host files: the human reads the script before `rc build`, and "compile arbitrary upstream source" remains a real supply-chain surface that review carries.

## Live instance: the DCG recipe

[examples/dcg/manifest-fragment.yaml](../../examples/dcg/manifest-fragment.yaml) is the in-repo from-source instance (illustration of the mechanism, not a blessed tool — DCG is a composable guard recipe per ADR-025 D2). Its `dcg` entry declares `builder_image: "rust:1-slim-trixie"`, `build_script: "tests/fixtures/build-dcg-from-source.sh"`, `output_path: "/usr/local/bin/dcg"` — pinned to a release tag, arch-adaptive, artifact-only into the runtime image. Read it alongside this doc rather than copying blindly: the fragment's second entry (`dcg-wiring`) is guard wiring, not part of the from-source mechanism.

The historical first instance was cm (CASSMS) — a Bun-compiled binary with no linux-arm64 upstream release, which is what motivated generalizing D6's "fall back to source" into this declarative stage (see [cm.md](cm.md) and ADR-005 D6/D11).

---

## See also

- [adding-a-tool.md](adding-a-tool.md) — the prebuilt (`install_cmd`) path; try that first
- [manifest-validator.md](manifest-validator.md) — every check a `build_source` entry passes, with error messages
- [docs/reference/README.md](README.md) — seam catalog
- [ADR-005 D6/D11/D12](../decisions/ADR-005-ecosystem-tools.md) — prefer-prebuilt, the three D11 mechanisms and their firmness split, illustration-only rule
