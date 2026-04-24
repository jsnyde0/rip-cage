# Paths
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

# History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory sharehistory hist_ignore_dups

# Basics
setopt autocd
autoload -Uz compinit && compinit

# Prompt: user@host cwd
PS1='%F{cyan}%n@%m%f %F{yellow}%~%f %# '

# Modern CLI aliases (conditional — no errors if tool missing)
command -v eza  &>/dev/null && alias ls='eza'    || \
command -v lsd  &>/dev/null && alias ls='lsd'    || true
command -v bat  &>/dev/null && alias cat='bat --paging=never'
command -v rg   &>/dev/null && alias grep='rg'

# Git aliases
alias gs='git status'
alias gd='git diff'
alias gp='git push'
alias gl='git log --oneline -20'
alias glog='git log --oneline --graph --all -30'
alias ga='git add'
alias gc='git commit'

# Utility functions
mkcd() { mkdir -p "$1" && cd "$1"; }

extract() {
  case "$1" in
    *.tar.gz|*.tgz)    tar xzf "$1" ;;
    *.tar.bz2|*.tbz2)  tar xjf "$1" ;;
    *.tar.xz)          tar xJf "$1" ;;
    *.zip)              unzip "$1" ;;
    *.gz)               gunzip "$1" ;;
    *.bz2)              bunzip2 "$1" ;;
    *)                  echo "Unknown archive: $1" ;;
  esac
}

# Terminal type fallback (containers sometimes lack terminfo)
[[ -z "$TERM" || "$TERM" == "dumb" ]] && export TERM=xterm-256color

# mise (project toolchain). No-op when no tool files are declared.
command -v /usr/local/bin/mise >/dev/null 2>&1 && eval "$(/usr/local/bin/mise activate zsh)"

# Rip-cage posture banner: ssh-agent forwarding status (ADR-017 D4). Surfaces
# the preflight result on every new shell so users see forward-ssh posture on
# every tmux attach, not just at rc up time (whose stdout is swallowed by the
# tmux auto-attach).
if [[ -r /etc/rip-cage/ssh-agent-status ]]; then
  _rc_ssh_status=$(cat /etc/rip-cage/ssh-agent-status 2>/dev/null)
  _rc_host_os=$(cat /etc/rip-cage/host-os 2>/dev/null)
  case "$_rc_ssh_status" in
    ok:*) echo "[rip-cage] ssh-agent: ${_rc_ssh_status#ok:} key(s) loaded — git push works" ;;
    empty)
      echo "[rip-cage] ssh-agent: forwarded but EMPTY (0 keys) — push will fail."
      if [[ "$_rc_host_os" == "darwin" ]]; then
        echo "  Host fix (macOS, one-time): add 'UseKeychain yes' + 'AddKeysToAgent yes' to ~/.ssh/config, then run on host:"
        echo "    ssh-add --apple-use-keychain ~/.ssh/id_ed25519"
      else
        echo "  Host fix: run on host:  ssh-add ~/.ssh/id_ed25519"
      fi
      echo "  Then: rc down && rc up  (or pass --no-forward-ssh to skip forwarding)"
      ;;
    unreachable)
      echo "[rip-cage] ssh-agent: mounted but UNREACHABLE — push will fail."
      if [[ "$_rc_host_os" == "darwin" ]]; then
        echo "  This usually means the host socket is a launchd session agent, not the system keychain agent."
        echo "  Host fix (macOS): ensure 'ssh-add --apple-use-keychain ~/.ssh/id_ed25519' was run at least once,"
        echo "  then 'rc down && rc up' to re-mount /run/host-services/ssh-auth.sock."
      else
        echo "  Host fix: verify ssh-agent is running ('ssh-add -l' on host), then 'rc down && rc up'."
      fi
      echo "  Or pass --no-forward-ssh to skip forwarding."
      ;;
    no_host_agent)
      echo "[rip-cage] ssh-agent: NO HOST AGENT available — forwarding inactive."
      echo "  Host fix: start ssh-agent on host ('eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519'),"
      echo "  then 'rc down && rc up'. Or pass --no-forward-ssh to silence."
      ;;
    disabled) echo "[rip-cage] ssh-agent: forwarding disabled (--no-forward-ssh). Push from host." ;;
  esac
  unset _rc_ssh_status _rc_host_os
fi
