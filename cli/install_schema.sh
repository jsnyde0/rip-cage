#!/usr/bin/env bash
# cli/install_schema.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


# cmd_install -- seed ~/.config/rip-cage/config.yaml with the default 16-pattern
# mounts.denylist.  Idempotent: no-op when file already matches the proposal
# (unless --force). Respects RC_CONFIG_GLOBAL override.
#
# Flags:
#   --yes / -y    Skip confirmation prompt; required when stdin is not a TTY.
#   --force       Overwrite even when the existing file matches the proposal.
cmd_install() {
  local _yes=0 _force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) _yes=1; shift ;;
      --force)  _force=1; shift ;;
      -*)
        echo "Error: unknown flag '$1' (rc install supports --yes, --force)" >&2
        exit 1 ;;
      *)
        echo "Error: unexpected argument '$1' (rc install takes no positional args)" >&2
        exit 1 ;;
    esac
  done

  local _cfg
  _cfg=$(_config_global_path)

  # Build proposal from single-source helper (rip-cage-j86: shared with auto-seed).
  local _proposed
  _proposed=$(_config_default_global_yaml)

  if [[ -f "$_cfg" ]]; then
    if diff -q "$_cfg" <(printf '%s\n' "$_proposed") >/dev/null 2>&1; then
      if [[ "$_force" -eq 0 ]]; then
        echo "rc install: $_cfg already matches the proposal; nothing to do."
        exit 0
      fi
    else
      echo "Existing $_cfg differs from proposed. Diff (current → proposed):"
      diff -u "$_cfg" <(printf '%s\n' "$_proposed") || true
    fi
  else
    echo "Proposed $_cfg:"
    echo "----"
    printf '%s\n' "$_proposed"
    echo "----"
  fi

  if [[ "$_yes" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: stdin is not a TTY; pass --yes to write non-interactively." >&2
      exit 1
    fi
    local _ans
    printf 'Write %s? [y/N] ' "$_cfg"
    read -r _ans
    case "$_ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi

  mkdir -p "$(dirname "$_cfg")"
  printf '%s\n' "$_proposed" > "$_cfg"
  echo "Wrote $_cfg"
}


cmd_schema() {
  cat <<'SCHEMA'
{
  "version": "1",
  "commands": {
    "up": {
      "args": [{"name": "path", "type": "path", "required": true}],
      "flags": {
        "--output": {"values": ["json"], "default": null},
        "--dry-run": {"type": "bool", "default": false},
        "--env-file": {"type": "path", "optional": true},
        "--port": {"type": "string", "optional": true},
        "--cpus": {"type": "string", "default": "2"},
        "--memory": {"type": "string", "default": "4g"},
        "--pids-limit": {"type": "string", "default": "500"}
      }
    },
    "down": {
      "args": [{"name": "name", "type": "string", "required": false, "note": "auto-selected if exactly one container exists"}],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "destroy": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {
        "--output": {"values": ["json"], "default": null},
        "--dry-run": {"type": "bool", "default": false},
        "--force": {"type": "bool", "default": false, "aliases": ["-f"], "note": "skip confirmation prompt"}
      }
    },
    "reload": {
      "args": [{"name": "name", "type": "string", "required": false, "note": "auto-selected via CWD or singleton"}],
      "flags": {
        "--dry-run": {"type": "bool", "default": false, "note": "print diff without mutating cache/snapshot"}
      }
    },
    "ls": {
      "args": [],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "test": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "doctor": {
      "args": [{"name": "name", "type": "string", "required": false, "note": "auto-selected via CWD convention or singleton"}],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "attach": {
      "args": [{"name": "name", "type": "string", "required": false}],
      "flags": {}
    },
    "exec": {
      "args": [{"name": "cage", "type": "string", "required": false, "note": "auto-selected if exactly one container exists"}],
      "flags": {
        "--output": {"values": ["json"], "default": null}
      },
      "variadic_trailing": {"separator": "--", "note": "command to run verbatim inside the container (word boundaries preserved)"}
    },
    "build": {
      "args": [],
      "flags": {"--output": {"values": ["json"], "default": null}}
    },
    "auth": {
      "subcommands": {
        "refresh": {
          "args": [],
          "flags": {"--output": {"values": ["json"], "default": null}}
        }
      }
    },
    "config": {
      "subcommands": {
        "show": {
          "args": [{"name": "path", "type": "string", "required": false}],
          "flags": {"--json": {"type": "bool", "default": false}}
        },
        "get": {
          "args": [
            {"name": "key", "type": "string", "required": true},
            {"name": "path", "type": "string", "required": false}
          ],
          "flags": {"--json": {"type": "bool", "default": false}}
        },
        "set": {
          "args": [
            {"name": "key", "type": "string", "required": true},
            {"name": "value", "type": "string", "required": true},
            {"name": "path", "type": "string", "required": false}
          ],
          "flags": {"--scope": {"type": "string", "values": ["global", "project"], "required": true, "default": null}}
        },
        "add": {
          "args": [
            {"name": "key", "type": "string", "required": true},
            {"name": "item", "type": "string", "required": true},
            {"name": "path", "type": "string", "required": false}
          ],
          "flags": {"--scope": {"type": "string", "values": ["global", "project"], "required": true, "default": null}}
        },
        "remove": {
          "args": [
            {"name": "key", "type": "string", "required": true},
            {"name": "item", "type": "string", "required": true},
            {"name": "path", "type": "string", "required": false}
          ],
          "flags": {"--scope": {"type": "string", "values": ["global", "project"], "required": true, "default": null}}
        }
      }
    },
    "schema": {
      "args": [],
      "flags": {}
    },
    "completions": {
      "args": [{"name": "shell", "type": "string", "required": true, "values": ["zsh", "bash"]}],
      "flags": {}
    },
    "setup": {
      "args": [],
      "flags": {}
    }
  }
}
SCHEMA
}

