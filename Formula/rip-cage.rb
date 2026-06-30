class RipCage < Formula
  desc "Docker sandbox for Claude Code agents with a safety stack"
  homepage "https://github.com/jsnyde0/rip-cage"
  url "https://github.com/jsnyde0/rip-cage/archive/refs/tags/v0.10.0.tar.gz"
  # PLACEHOLDER — updated post-tag by scripts/update-formula-sha.sh.
  # See "Release ceremony" in docs/decisions/ADR-008-open-source-publication.md D6/D8.
  sha256 "cc93a12f348a827e4fb177117f54df20cc561ba46e02e160a9b9f7f1990719ff"
  license "MIT"

  head "https://github.com/jsnyde0/rip-cage.git", branch: "main"

  depends_on "jq"
  depends_on "yq"

  def caveats
    <<~EOS
      rip-cage needs Docker (or OrbStack) installed and running.

      On first `rc up`, the pre-built image is pulled from GHCR (~30s).
      If GHCR is unreachable, rc falls back to a local docker build (5-10 min).

      To always build locally (e.g. for Dockerfile development):
        export RIP_CAGE_IMAGE_REGISTRY=""

      Quick start: https://github.com/jsnyde0/rip-cage#quick-start
    EOS
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"rc"
    zsh_completion.install libexec/"completions/_rc" => "_rc"
    bash_completion.install libexec/"completions/rc.bash" => "rc"
  end

  test do
    # Basic wiring: rc --version prints the VERSION file contents.
    assert_match version.to_s, shell_output("#{bin}/rc --version")
    # Layout: _resolve_script_dir (rc:6-16) follows the bin/rc symlink to
    # libexec/. The Dockerfile and friends must be reachable from there for
    # cmd_build to find them — verify the layout is intact.
    assert_predicate libexec/"Dockerfile", :exist?
    assert_predicate libexec/"init-rip-cage.sh", :exist?
    assert_predicate libexec/"hooks/block-compound-commands.sh", :exist?
    assert_predicate libexec/"VERSION", :exist?
  end
end
