# Bash completion for rc
# Compatible with Bash 3.2 (macOS default) — no associative arrays, no ${var,,}

_rc_complete() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="build init up ls attach down destroy test auth schema completions setup"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    return 0
  fi

  case "$prev" in
    attach|down|test)
      local containers
      containers=$(docker ps --filter label=rc.source.path --format '{{.Names}}' 2>/dev/null)
      COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
      ;;
    destroy)
      local containers
      containers=$(docker ps -a --filter label=rc.source.path --format '{{.Names}}' 2>/dev/null)
      COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
      ;;
    up|init)
      COMPREPLY=( $(compgen -d -- "$cur") )
      ;;
    auth)
      COMPREPLY=( $(compgen -W "refresh" -- "$cur") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
  esac
}

complete -F _rc_complete rc
