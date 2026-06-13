# Bash completion for rc
# Compatible with Bash 3.2 (macOS default) — no associative arrays, no ${var,,}

_rc_complete() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="build init up ls attach exec down destroy reload test doctor auth config schema completions setup agent sessions"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    return 0
  fi

  case "$prev" in
    attach|exec|down|test|reload|agent|sessions)
      local containers
      containers=$(docker ps --filter label=rc.source.path --format '{{.Names}}' 2>/dev/null)
      COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
      ;;
    destroy|doctor)
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
    config)
      COMPREPLY=( $(compgen -W "show" -- "$cur") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
  esac
}

complete -F _rc_complete rc
