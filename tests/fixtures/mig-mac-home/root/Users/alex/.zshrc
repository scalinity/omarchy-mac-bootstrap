# Zsh for alex (fixture)
export EDITOR=nvim
export LESS="-R"
export BAT_THEME='Dracula'
export HISTSIZE=10000
export PATH="/opt/homebrew/bin:$PATH"
export HOMEBREW_NO_ANALYTICS=1
export NOTES_DIR=/Users/alex/notes
export RIPGREP_CONFIG_PATH=/Users/alex/.config/ripgrep/rc
alias gs='git status'
alias ll="ls -la"
alias cpwd='pwd | pbcopy'
alias ls='ls -G'
alias greet='echo $USER'
alias plain=ls
alias -g G='| grep'
touch "$HOME/omb-sourced-zshrc"
if [[ $OSTYPE == darwin* ]]; then
  alias inside_if='echo nested'
fi
mkcd() {
  alias inside_fn='echo fn'
  mkdir -p "$1" && cd "$1"
}
cat <<EOF >/dev/null
alias inside_heredoc='echo heredoc'
EOF
alias after_heredoc='echo after'
source ~/.oh-my-zsh/oh-my-zsh.sh
setopt autocd
bindkey -e
