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
  _rc_ssh_socket=$(cat /etc/rip-cage/ssh-agent-socket 2>/dev/null)
  case "$_rc_ssh_status" in
    ok:*) echo "[rip-cage] ssh-agent: ${_rc_ssh_status#ok:} key(s) loaded — git push works" ;;
    empty)
      echo "[rip-cage] ssh-agent: forwarded but EMPTY (0 keys) — push will fail."
      echo "  Host agent: ${_rc_ssh_socket:-<unknown>} has no keys loaded."
      if [[ "$_rc_ssh_socket" == "/run/host-services/ssh-auth.sock" ]]; then
        # macOS via OrbStack/Docker Desktop — only the launchd agent is proxied
        # across the VM boundary, NOT the user's shell session agent. Adding keys
        # to the session agent (default 'ssh-add') is invisible to the cage.
        echo "  Fix (macOS): SSH_AUTH_SOCK=\$(launchctl getenv SSH_AUTH_SOCK) ssh-add ~/.ssh/id_ed25519"
        echo "  This populates the launchd agent the OrbStack/Docker Desktop proxy actually forwards."
        echo "  Then: rc down && rc up. Or pass --no-forward-ssh to skip forwarding."
      else
        echo "  Fix: run 'ssh-add ~/.ssh/id_ed25519' on host, then 'rc down && rc up'"
        echo "  Or pass --no-forward-ssh to skip forwarding."
      fi
      ;;
    unreachable)
      echo "[rip-cage] ssh-agent: socket UNREACHABLE — push will fail."
      echo "  Socket: ${_rc_ssh_socket:-<unknown>} mounted but not responding."
      if [[ "$_rc_ssh_socket" == "/run/host-services/ssh-auth.sock" ]]; then
        # The most common cause on macOS is a permission mismatch on the mounted
        # socket (host uid != container agent uid). init-rip-cage.sh chown'd it
        # at start; if this still trips, the image likely predates the sudoers
        # entry and needs a rebuild.
        echo "  Likely cause: cage agent user cannot reach the host-forwarded socket."
        echo "  Fix: ./rc build && rc down && rc up (rebuild picks up sudoers chown grant)."
        echo "  If that fails: verify host ssh-agent is running ('ssh-add -l' on host)."
      else
        echo "  Fix: verify ssh-agent is running on host ('ssh-add -l'), then 'rc down && rc up'"
      fi
      echo "  Or pass --no-forward-ssh to skip forwarding."
      ;;
    no_host_agent)
      echo "[rip-cage] ssh-agent: NO HOST AGENT available — forwarding inactive."
      echo "  Host fix: start ssh-agent on host ('eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519'),"
      echo "  then 'rc destroy && rc up'. Or pass --no-forward-ssh to silence."
      ;;
    disabled) echo "[rip-cage] ssh-agent: forwarding disabled (--no-forward-ssh). Push from host." ;;
  esac
  unset _rc_ssh_status _rc_ssh_socket
fi
