# AGENTS.md: what an agent working on the fleet must know, rendered from the
# fleet's metadata alone (host.nix, service.nix, user.nix, mkFlake's
# arguments), so no host is evaluated for it.
#
#   fleet { name; repo; hosts; services; users; caches; extra; }
#                       the repository's AGENTS.md (`fleetl agents sync`)
#   host { name; repo; hosts; services; users; caches; hostName; }
#                       one host's part of it, the head of its /etc/AGENTS.md
#                       (fleet.agents appends what its configuration adds)
#   rules presence      the hardware key rules (null: no reader registered)
#
# The rules are the practice of mind-the-gap and nix-piv: PIN tries are
# scarce, a touch needs a person, scdaemon takes every reader, and a card
# under a running agent must not be opened exclusively.
{ lib }:
let
  inherit (lib) concatStringsSep concatMapStringsSep optionalString;
  inherit (import ./smartcard.nix { inherit lib; }) readersText;

  list = xs: if xs == [ ] then "-" else concatStringsSep ", " xs;
  codes = xs: if xs == [ ] then "-" else concatMapStringsSep ", " (x: "`${x}`") xs;
  cell = s: lib.replaceStrings [ "|" "\n" ] [ "\\|" " " ] s;
  row = cells: "| ${concatMapStringsSep " | " cell cells} |";
  table =
    header: rows:
    concatStringsSep "\n" (
      [
        (row header)
        (row (map (_: "---") header))
      ]
      ++ map row rows
    );
  paragraphs = ps: concatStringsSep "\n\n" (lib.filter (p: p != "") ps) + "\n";

  # How an admin pushes a closure the hosts' daemons would refuse (unsigned,
  # nobody but root trusted): through sudo, authenticated by the forwarded agent.
  pushCommand =
    host: "nix copy --no-check-sigs --to 'ssh-ng://${host}?remote-program=sudo%20nix-daemon' <path>";

  presenceText = sc: if sc == null then "none registered" else sc.presence;

  # --- the rules -------------------------------------------------------------
  commonRules = ''
    - **Never guess a PIN or retry one in a loop.** A PIV PIN has three tries,
      and cards provisioned with mind-the-gap have their PUK blocked: a blocked
      PIN means provisioning the card again. When a PIN is needed, the user
      types it.
    - **Never reset, provision or rewrite a card** (`mind-the-gap ... upload`,
      `ykman piv reset`, `ykman piv keys generate`, `ykman openpgp reset`,
      `nix-piv-provision`, admin commands in `gpg --card-edit`) unless the user
      asked for exactly that, for a card they named by its serial. Never pick
      whatever card is plugged in (`$(ykman list --serials)`).
    - Prefer probes that spend no PIN and need no touch: `opensc-tool -l`,
      `ykman list`, `gpg-card list --cards`, `mind-the-gap cards`.
    - **gpg's scdaemon holds every reader exclusively** for as long as it runs.
      After gpg used a card, `gpgconf --kill scdaemon` before PIV tools (ssh
      through PKCS#11, ykman, OpenSC, nix-piv); "other connections
      outstanding", or a card that seems gone, usually means this.'';

  # The repository is worked on at a machine with a person at it.
  touchRule = ''
    - Signing a commit, pushing, or connecting to a host may need the user's
      key, and so their PIN or touch: say so before starting, run it in the
      foreground, and do not retry a failed signature on your own.'';

  registeredRules = ''
    - **Only registered readers exist.** pcscd ignores every USB reader not
      registered for the host (udev `PCSCLITE_IGNORE`), so gpg, OpenSC and
      ykman's smartcard interface do not see them either. A card that does not
      show up is unregistered or unplugged: register it (`smartcard.readers` in
      `host.nix`, or mkFlake's `smartcard` for every host) instead of working
      around the filter. Only the smartcard (CCID) interface is filtered; FIDO2,
      U2F and OTP are not.'';

  attendedRules = ''
    - **Someone is present and can touch the key, but only when asked.** An
      operation that needs a touch makes the key blink and fails after about
      fifteen seconds without one. Say so before starting it, run it in the
      foreground, and do not retry on your own. A missed touch shows up as
      `C_Sign failed: 257`, `agent refused operation`, `sign_and_send_pubkey:
      signing failed` or a timeout, never as "touch required".
    - A desktop notification (yubikey-touch-detector) shows while a key waits
      for gpg or FIDO; PIV through PKCS#11 gives none.
    - Cards are reachable from the local graphical session only (pcsc-lite's
      polkit policy); over SSH and from system services they are refused, by
      design.
    - SSH connections to fleet hosts are multiplexed for ten minutes, so a
      series of commands to one host costs one touch.'';

  headlessRules = ''
    - **Nobody is present: nothing may wait for a touch or a PIN prompt.** The
      key is provisioned without touch and with its PIN verified once per
      session (mind-the-gap `--policy once-pin`, or `nix-piv-provision`), and
      is unlocked at boot from a sealed PIN.
    - Use the key through its agent (nix-piv's `piv-agent`, whose socket each
      host's `/etc/AGENTS.md` names), never directly. Never read, decrypt
      or print the sealed PIN (`/var/lib/piv-agent/pin.cred`); sealing it again
      is `nix-piv-seal-pin`, on the user's request.
    - Do not run `ykman` or gpg against the card: ykman connects exclusively
      and powers the card off on disconnect, which ends the agent's login, and
      scdaemon takes the reader away. Recover with `systemctl restart
      piv-agent-unlock`, or `systemctl restart piv-agent` after the card was
      unplugged. `nix-piv info` and `nix-piv pubkeys` connect shared and are
      safe.'';

  rules =
    presence:
    if presence == null then
      commonRules
    else
      concatStringsSep "\n" [
        commonRules
        registeredRules
        (if presence == "attended" then attendedRules else headlessRules)
      ];

  # --- facts about one host --------------------------------------------------
  hostFacts =
    {
      hosts,
      services,
      users,
      caches,
      hostName,
    }:
    let
      h = hosts.${hostName};
      sc = h.smartcard or null;
      roles =
        s: builtins.attrNames (lib.filterAttrs (_: r: builtins.elem hostName r.hosts) services.${s}.roles);
      serviceText = s: if roles s == [ "default" ] then "`${s}`" else "`${s}` (${list (roles s)})";
      userText = u: "`${u}`" + optionalString (users.${u}.admin or false) " (admin)";
      served = lib.filter (c: c.host == hostName) caches;
      data = builtins.removeAttrs h [
        "name"
        "system"
        "importance"
        "layers"
        "services"
        "users"
        "generators"
        "smartcard"
        "keys"
        "cache"
      ];
      scalar = v: builtins.isString v || builtins.isInt v || builtins.isBool v;
      dataText = n: v: if scalar v then "`${n}` = `${toString v}`" else "`${n}`";
    in
    concatStringsSep "\n" (
      [
        "- system `${h.system}`, importance `${h.importance}`"
        "- services: ${if h.services == [ ] then "-" else concatMapStringsSep ", " serviceText h.services}"
        "- layers: ${codes h.layers}"
        "- users: ${if h.users == [ ] then "-" else concatMapStringsSep ", " userText h.users}"
        "- public keys: ${codes (builtins.attrNames (h.keys or { }))}"
      ]
      ++ lib.optional (data != { }) "- data: ${concatStringsSep ", " (lib.mapAttrsToList dataText data)}"
      ++ lib.optional (served != [ ]) "- serves the binary cache ${codes (map (c: c.url) served)}"
      ++ [
        (
          if sc == null then
            "- hardware key: no smartcard reader registered"
          else
            # the readers themselves are listed by fleet.smartcard's section
            "- hardware key: **${sc.presence}**, ${toString (builtins.length (builtins.attrNames sc.readers))} reader(s) registered"
        )
      ]
    );

  repoText = repo: optionalString (repo != null) " (`${repo}`)";
in
{
  inherit rules pushCommand;

  fleet =
    {
      name,
      repo ? null,
      hosts,
      services ? { },
      users ? { },
      caches ? [ ],
      extra ? [ ],
    }:
    let
      hostNames = builtins.attrNames hosts;
      withReaders = lib.filterAttrs (_: h: h.smartcard or null != null) hosts;
      presences = lib.unique (lib.mapAttrsToList (_: h: h.smartcard.presence) withReaders);
      hasLayers = lib.any (h: h.layers != [ ]) (builtins.attrValues hosts);

      hostRows = map (
        n:
        let
          h = hosts.${n};
        in
        [
          "`${n}`"
          h.system
          h.importance
          (codes h.services)
          (codes h.layers)
          (codes h.users)
          (presenceText (h.smartcard or null))
        ]
      ) hostNames;

      readerLines = lib.mapAttrsToList (
        n: h: "- `${n}` (${h.smartcard.presence}): ${readersText h.smartcard.readers}"
      ) withReaders;

      allHosts = u: lib.sort (a: b: a < b) u.hosts == hostNames;
      userRows = lib.mapAttrsToList (n: u: [
        "`${n}`"
        (if u.admin then "yes" else "no")
        (if allHosts u then "all" else codes u.hosts)
        (codes u.services)
      ]) users;

      serviceRows = lib.mapAttrsToList (n: s: [
        "`${n}`"
        (concatStringsSep "; " (
          lib.mapAttrsToList (
            r: rv: if r == "default" then codes rv.hosts else "${r}: ${codes rv.hosts}"
          ) s.roles
        ))
        (codes s.layers)
      ]) services;

      extraText = map (e: if builtins.isString e then e else builtins.readFile e) extra;
    in
    paragraphs (
      [
        "# AGENTS.md: the ${name} fleet"
        ''
          <!-- Written by `fleetl agents sync` from the fleet's metadata (host.nix,
          service.nix, user.nix and mkFlake's arguments). Edit those, not this
          file: the fleet-agents check fails while it is stale. -->''
        ''
          This repository is the NixOS fleet **${name}**${repoText repo}, laid out
          for ftl: `ftl.lib.mkFlake` in `flake.nix` turns every folder into flake
          outputs. Every host also carries its own part of this file as
          `/etc/AGENTS.md`, with what its configuration adds.''
        "## Layout"
        ''
          - `nixos/hosts/<host>/`: one folder per host. `host.nix` is metadata (a
            plain attribute set, never a module): `system`, `importance`, `layers`,
            `smartcard`, plus free-form data such as `fqdn`. Every other `.nix` file
            there is a module of that host; `*.pub` files are its public keys.
          - `nixos/services/<service>/`: modules imported on the hosts its
            `service.nix` names; moving a service is editing that list.
          - `nixos/modules/`: imported into every host; `nixos/profiles/`: opt-in
            building blocks (the `profiles` argument).
          - `nixos/layers/<layer>.nix`: Nix profiles updated without a system
            rebuild; `ftl-layers.json` pins their revisions.
          - `home/`: home-manager modules, profiles and variants; configurations
            are named `<base>-<variant>`.
          - `users/<user>/`: `user.nix` (where the user has an account) and
            `ssh.pub` (the keys for login, sudo and deploying).
          - `pkgs/`: own packages and the overlay; `static/`: files the modules
            reference as `static.<name>`.''
        "## Working here"
        ''
          - Nix sees only files known to git: `git add` new files (intent-to-add,
            `git add -N`, is enough).
          - Check a change with `nix flake check`, or one host with `nix build
            .#nixosConfigurations.<host>.config.system.build.toplevel`.
          - Generated files are never edited by hand: `.sops.yaml` (`fleetl secrets
            sync`), `AGENTS.md` (`fleetl agents sync`) and `ftl-layers.json`
            (written by the build pipeline). `fleetl` is `nix run .#fleetl -- ...`.
          - Secrets live in sops stores (`secrets.yaml`, `identity.yaml`) next to
            what they belong to. Never decrypt one into the working tree, print a
            secret, or commit plaintext; `fleetl secrets edit <store>` opens one.
          - Hosts change through this repository, not by hand: what is deployed is
            what the branch says, and changes made on a machine are lost with the
            next deployment.''
        "## Hosts"
        (table [
          "host"
          "system"
          "importance"
          "services"
          "layers"
          "users"
          "hardware key"
        ] hostRows)
        ''
          A `required` host that fails to build blocks the update of the fleet, an
          `optional` one does not, and an `ignored` one is not built.''
        (optionalString hasLayers ''
          Layers are installed and rolled back on a host with `ftl-layers update |
          list | rollback <layer>`, never with `nix-env`.'')
        "## Hardware keys"
        ''
          Keys are used for SSH logins, sudo, commit signing and, on build hosts,
          signing the binary cache. On an **attended** host a person is there to
          touch the key when asked; on a **headless** one nobody is, and its key
          works without touch. Hosts without registered readers leave smartcards
          alone.''
        (optionalString (readerLines != [ ]) (concatStringsSep "\n" readerLines))
        (concatStringsSep "\n" (
          [
            commonRules
            touchRule
          ]
          ++ lib.optional (readerLines != [ ]) registeredRules
        ))
      ]
      ++ lib.optionals (builtins.elem "attended" presences) [
        "### On attended hosts"
        attendedRules
      ]
      ++ lib.optionals (builtins.elem "headless" presences) [
        "### On headless hosts"
        headlessRules
      ]
      ++ lib.optionals (caches != [ ]) [
        "## Binary caches"
        (concatMapStringsSep "\n" (
          c: "- ${c.url}, served by `${c.host}`, signed by ${codes c.publicKeys}"
        ) caches)
      ]
      ++ lib.optionals (services != { }) [
        "## Services"
        (table [
          "service"
          "hosts"
          "layers"
        ] serviceRows)
      ]
      ++ lib.optionals (users != { }) [
        "## Users"
        (table [
          "user"
          "admin"
          "hosts"
          "services"
        ] userRows)
        ''
          Accounts are key-only. sudo authenticates against the SSH agent the user
          forwards (pam_rssh): it fails without one, and with a touch-policy key it
          needs a touch.''
        ''
          The hosts' Nix daemons trust nobody but root (unless a host sets
          `fleet.nix.trustWheel`). Closures the fleet's builder built carry the
          cache's signature and copy as they are. One built elsewhere is pushed
          through sudo first, which needs the forwarded agent (and a touch):

          ```
          ${pushCommand "<host>"}
          ```

          `nixos-rebuild --target-host <host> --sudo` or deploy-rs then find the
          paths in place.''
      ]
      ++ extraText
    );

  host =
    {
      name,
      repo ? null,
      hosts,
      services ? { },
      users ? { },
      caches ? [ ],
      hostName,
    }:
    let
      sc = hosts.${hostName}.smartcard or null;
    in
    paragraphs [
      "# AGENTS.md: ${hostName}, a host of the ${name} fleet"
      ''
        <!-- Written by ftl from the fleet's metadata and this host's
        configuration. -->''
      ''
        This machine is the host **${hostName}** of the NixOS fleet **${name}**.
        Its configuration is `nixos/hosts/${hostName}/` in the fleet's
        repository${repoText repo}; change it there, not here: `/etc` is
        generated, and what is deployed is what the repository says.''
      "## This host"
      (hostFacts {
        inherit
          hosts
          services
          users
          caches
          hostName
          ;
      })
      "## Hardware keys"
      (
        if sc == null then
          "No smartcard reader is registered for this host, so ftl leaves smartcards alone here. Should one be plugged in anyway:\n\n"
          + rules null
        else
          rules sc.presence
      )
    ];
}
