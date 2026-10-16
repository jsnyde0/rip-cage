class RipCage < Formula
  desc "Tested microsandbox (msb) distribution for running Claude Code with permissions off"
  homepage "https://github.com/jsnyde0/rip-cage"
  url "https://github.com/jsnyde0/rip-cage/archive/refs/tags/v0.13.1.tar.gz"
  # PLACEHOLDER — updated post-tag by packaging/scripts/update-formula-sha.sh.
  # See "Release ceremony" in docs/decisions/ADR-008-open-source-publication.md D6/D8.
  sha256 "7f3d8f49344050585d14f62414b25d8f97cf00c30f4bc8cad7ff699ff3b5e66f"
  license "MIT"

  head "https://github.com/jsnyde0/rip-cage.git", branch: "main"

  depends_on "jq"
  depends_on "yq"

  def caveats
    <<~EOS
      rip-cage runs cages on microsandbox (msb), which Homebrew does not
      provide. Install msb 0.7.4 or newer yourself (`msb update` upgrades it);
      `rc up` refuses an older msb.

      Docker is needed only to build the agent image (`rc build`), which
      loads it into msb. msb, not Docker, runs the cage.

      Quick start: https://github.com/jsnyde0/rip-cage#quick-start
    EOS
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"rc"
  end

  test do
    # Basic wiring: rc --version prints the VERSION file contents.
    assert_match version.to_s, shell_output("#{bin}/rc --version")
    # Layout: _resolve_script_dir (rc:_resolve_script_dir) follows the bin/rc symlink to
    # libexec/. The Dockerfile and friends must be reachable from there for
    # cmd_build to find them — verify the layout is intact.
    assert_predicate libexec/"cage/Dockerfile", :exist?
    assert_predicate libexec/"cage/init/init-rip-cage.sh", :exist?
    assert_predicate libexec/"VERSION", :exist?
  end
end
