# App-owned Bash session launcher. User profiles are preserved separately.
case $- in *i*) ;; *) return ;; esac
. "$HOME/.qeltravyx/profile.sh"
. "$HOME/.qeltravyx/bashrc"

# Inherit the PTY's cwd (HOME for a new session); nested shells keep their cwd.
# Readline must exclude ANSI bytes from its cursor/line-width calculations.
PS1='\[\e[1;32m\]\w\[\e[0m\] $ '
