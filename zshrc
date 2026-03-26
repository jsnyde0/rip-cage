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
