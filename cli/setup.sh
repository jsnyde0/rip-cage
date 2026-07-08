#!/usr/bin/env bash
# cli/setup.sh -- extracted from rc (behavior-preserving decomposition, rip-cage-gto1).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).


cmd_setup() {
  # Detect login shell from $SHELL
  local shell_name
  shell_name="$(basename "${SHELL:-}")"

  # Determine config file (same heuristic as fzf)
  local config_file=""
  case "$shell_name" in
    zsh)
      if [[ -f "${HOME}/.zshrc" ]]; then
        config_file="${HOME}/.zshrc"
      else
        config_file="${HOME}/.zprofile"
      fi
      ;;
    bash)
      if [[ -f "${HOME}/.bashrc" ]]; then
        config_file="${HOME}/.bashrc"
      elif [[ -f "${HOME}/.bash_profile" ]]; then
        config_file="${HOME}/.bash_profile"
      else
        config_file="${HOME}/.bashrc"
      fi
      ;;
    fish)
      echo "rc setup: fish shell is not yet supported." >&2
      echo "  PRs welcome: https://github.com/jsnyde0/rip-cage" >&2
      exit 1
      ;;
    "")
      # shellcheck disable=SC2016  # literal $SHELL in error message
      echo 'Error: $SHELL is not set. Set it or use rc completions <shell> directly.' >&2
      exit 1
      ;;
    *)
      echo "Error: unsupported shell '${shell_name}'. Supported: zsh, bash" >&2
      echo "  Use 'rc completions <shell>' to get the raw script." >&2
      exit 1
      ;;
  esac

  local eval_line="eval \"\$(rc completions ${shell_name})\""

  # Print header
  echo ""
  echo "rc setup — shell integration"
  echo ""
  echo "  Shell detected: ${shell_name}"
  echo "  Config file:    ${config_file}"
  echo ""
  echo "  This will add the following line to ${config_file}:"
  echo ""
  echo "    ${eval_line}"
  echo ""
  echo "  This enables:"
  echo "    - Tab completion for rc commands (build, up, down, ls, ...)"
  echo "    - Tab completion for container names (rc down <TAB>)"
  echo ""

  # Idempotency check: relaxed pattern catches user-modified eval lines
  if grep -q "rc completions" "${config_file}" 2>/dev/null; then
    echo "Shell completions already configured in ${config_file}."
    echo "To reload: exec ${shell_name}"
    exit 0
  fi

  # Ask for consent — default No (FIRM per ADR-011 D3)
  printf "  Add shell completions to %s? [y/N] " "${config_file}"
  local reply
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      printf '\n# rc shell completions (added by rc setup)\n%s\n' "${eval_line}" >> "${config_file}"
      echo ""
      echo "Done. Shell completions added to ${config_file}."
      echo "Reload your shell to activate: exec ${shell_name}"
      ;;
    *)
      echo ""
      echo "Skipped. To set up manually, add this to ${config_file}:"
      echo ""
      echo "  ${eval_line}"
      echo ""
      echo "Or run 'rc completions ${shell_name}' to see the full script."
      ;;
  esac
}

