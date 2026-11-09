"""Host-side behavior check for cage/substrate/own-agent-dir (rip-cage-rsh9.1).

Usage: python -I tests/own-agent-dir-check.py <path to own-agent-dir>

Loads the helper as a module and drives its core, fix(home, target, uid, gid),
against a scratch home the caller owns. Ownership cannot change without root, so
each case asserts on what the helper DID (its return code and the paths it
reports chowning or skipping), not on a resulting owner. The live cage probe in
tests/test-safety-stack.sh asserts on the owner itself.
Exit 0 and a one-line summary on success; exit 1 naming the first failed case.
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile


def load(path):
    loader = importlib.machinery.SourceFileLoader("own_agent_dir", path)
    spec = importlib.util.spec_from_loader("own_agent_dir", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    mod = load(sys.argv[1])
    uid, gid = os.getuid(), os.getgid()
    failures = []
    cases = 0

    def case(name, ok):
        nonlocal cases
        cases += 1
        if not ok:
            failures.append(name)

    with tempfile.TemporaryDirectory() as root:
        home = os.path.join(root, "home")
        outside = os.path.join(root, "outside")
        os.makedirs(os.path.join(outside, "agent"))
        os.makedirs(os.path.join(outside, "share", "mise"))
        victim = os.path.join(outside, "victim")
        open(victim, "w").close()

        # 1. A real directory is accepted and chowned.
        os.makedirs(os.path.join(home, ".claude"))
        rc, done, skipped = mod.fix(home, "claude", uid, gid)
        case("real dir accepted", rc == 0 and done == [os.path.join(home, ".claude")])

        # 2. A missing target is a no-op, not an error.
        rc, done, skipped = mod.fix(home, "claude-state", uid, gid)
        case("missing target is a no-op", rc == 0 and done == [])

        # 3. The final component a symlink to a file: refused, nothing chowned.
        os.symlink(victim, os.path.join(home, ".claude-state"))
        rc, done, skipped = mod.fix(home, "claude-state", uid, gid)
        case("final-component symlink refused", rc == 2 and done == [])

        # 4. An intermediate component a symlink (~/.pi -> a dir holding agent/).
        os.symlink(outside, os.path.join(home, ".pi"))
        rc, done, skipped = mod.fix(home, "pi-agent", uid, gid)
        case("intermediate symlink refused", rc == 2 and done == [])

        # 5. Recursive target: symlinks inside are not followed, hardlinked
        #    files are skipped, ordinary files are chowned.
        mise = os.path.join(home, ".local", "share", "mise")
        os.makedirs(os.path.join(mise, "sub"))
        plain = os.path.join(mise, "sub", "plain")
        open(plain, "w").close()
        os.symlink(outside, os.path.join(mise, "escape"))
        hl = os.path.join(mise, "hl")
        os.link(victim, hl)
        rc, done, skipped = mod.fix(home, "mise", uid, gid)
        case("recursive: plain file chowned", rc == 0 and plain in done)
        case("recursive: hardlink skipped", hl in skipped and hl not in done)
        case("recursive: nothing outside the tree touched",
             not any(p.startswith(outside) for p in done))
        case("recursive: symlink not followed",
             os.path.join(mise, "escape") not in done)

        # 6. Unknown target names are refused (usage).
        rc, done, skipped = mod.fix(home, "etc", uid, gid)
        case("unknown target refused", rc == 64 and done == [])

    if failures:
        print("FAILED: " + "; ".join(failures))
        return 1
    print(f"{cases} cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
