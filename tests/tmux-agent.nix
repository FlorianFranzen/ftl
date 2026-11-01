# fleet.access.tmuxAgent: the tmux.conf the access module writes, on a tmux
# server of its own.  A client attaching with one agent gets the link to that
# agent, even when a newer one exists; without a client, the newest agent
# that answers wins over a newer dead socket.
{
  pkgs,
  ftl,
  nixpkgs,
  ...
}:
let
  host = nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      ftl.nixosModules.access
      {
        fleet.access.users.alice.admin = true;
        programs.tmux.enable = true;
        system.stateVersion = "25.05";
      }
    ];
  };
  inherit (host.config.environment.etc."tmux.conf") source;
  agent = builtins.head (
    builtins.match ".*run-shell '([^ ]*/bin/tmux-ssh-agent) .*" (builtins.readFile source)
  );
in
assert host.config.fleet.access.tmuxAgent;
pkgs.runCommand "ftl-tmux-agent"
  {
    nativeBuildInputs = with pkgs; [
      tmux
      openssh
      util-linux # script
      python3
    ];
    
  }
  ''
    export HOME=$(mktemp -d /tmp/h.XXXX) TMUX_TMPDIR=$HOME
    mkdir -p $HOME/.ssh/agent
    a=$HOME/.ssh/agent/s.a.sshd.x b=$HOME/.ssh/agent/s.b.sshd.x
    eval $(ssh-agent -a $a) >/dev/null; pa=$SSH_AGENT_PID; touch -d '2 minutes ago' $a
    eval $(ssh-agent -a $b) >/dev/null; pb=$SSH_AGENT_PID; touch -d '1 minute ago' $b

    SSH_AUTH_SOCK=$a timeout 10 script -qec \
      "tmux -f ${source} new-session -s t 'sleep 2'" /dev/null >/dev/null || true
    [ "$(readlink $HOME/.ssh/agent.sock)" = $a ] || { echo "attach: $(readlink $HOME/.ssh/agent.sock), not $a"; exit 1; }

    python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('$HOME/.ssh/agent/s.c.sshd.x')"
    [ "$(${agent})" = $b ] || { echo "fallback did not pick $b"; exit 1; }

    kill $pa $pb; sleep 1
    ! ${agent} 2>/dev/null || { echo "no agent answers, yet it succeeded"; exit 1; }
    echo ok > $out
  ''
