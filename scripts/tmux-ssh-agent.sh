# tmux-ssh-agent [CLIENT-PID]: points ~/.ssh/agent.sock at the SSH agent of
# that tmux client, or else at the newest forwarded agent that answers, and
# prints it; fails if none does.  The access module's tmux hooks run it with
# the client that attached or was used last.
link="$HOME/.ssh/agent.sock"

# ssh-add -l exits 2 only if it cannot reach the agent; listing keys needs
# neither PIN nor touch.
use() {
  [ -S "$1" ] && [ "$(readlink -f "$1")" != "$(readlink -f "$link")" ] || return 1
  rc=0
  SSH_AUTH_SOCK="$1" timeout 5 ssh-add -l >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return 1
  ln -sfn "$1" "$link.new"
  mv -T "$link.new" "$link"
  echo "$1"
  exit 0
}

# The tmux client inherited the agent of the shell it was started from:
# forwarded over SSH, or the local one at the machine itself.
if [ -n "${1:-}" ] && [ -r "/proc/$1/environ" ]; then
  sock=$(tr '\0' '\n' <"/proc/$1/environ" | sed -n 's/^SSH_AUTH_SOCK=//p')
  [ -z "$sock" ] || use "$sock" || true
fi

# sshd's forwarded sockets (OpenSSH 10.1 and later), newest first.
while read -r _ sock; do
  use "$sock" || true
done < <(
  find "$HOME/.ssh/agent" -maxdepth 1 -type s -name 's.*.sshd.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn
)

echo "tmux-ssh-agent: no agent answers" >&2
exit 1
