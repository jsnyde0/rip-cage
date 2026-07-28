# Bash completion for rc
# Compatible with Bash 3.2 (macOS default) — no associative arrays, no ${var,,}

# _rc_completion_cage_names -- rip-cage-tsf2.5: enumerate rc-managed cage
# names for tab completion via the same msb/rc-native path `rc ls` itself
# uses, replacing the retired docker-based `ps` lookup (there is no docker daemon behind
# cages post-msb-cutover). Shells out to `rc --output json ls` (the real
# enumeration logic — label filtering, msb inspection -- lives there once;
# completion just consumes it) and extracts names with jq. Pass
# --running-only to restrict to cages with status "running" (mirrors the old
# docker's running-only vs all-containers `ps` split for attach/exec/down/test/reload vs
# destroy/doctor). Fails silently (empty completions) if rc or jq are
# unavailable -- same degrade-gracefully behavior as the old docker-based call.
_rc_completion_cage_names() {
  local _filter='.[].name'
  [[ "${1:-}" == "--running-only" ]] && _filter='.[] | select(.status=="running") | .name'
  command rc --output json ls 2>/dev/null | jq -r "$_filter" 2>/dev/null
}

_rc_complete() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="build up ls attach exec down destroy reload test doctor auth config schema completions setup"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    return 0
  fi

  case "$prev" in
    attach|exec|down|test|reload)
      local containers
      containers=$(_rc_completion_cage_names --running-only)
      COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
      ;;
    destroy|doctor)
      local containers
      containers=$(_rc_completion_cage_names)
      COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
      ;;
    up)
      COMPREPLY=( $(compgen -d -- "$cur") )
      ;;
    auth)
      COMPREPLY=( $(compgen -W "refresh" -- "$cur") )
      ;;
    config)
      COMPREPLY=( $(compgen -W "show get set add remove" -- "$cur") )
      ;;
    --scope)
      COMPREPLY=( $(compgen -W "global project" -- "$cur") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") )
      ;;
  esac
}

complete -F _rc_complete rc
