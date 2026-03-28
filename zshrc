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
