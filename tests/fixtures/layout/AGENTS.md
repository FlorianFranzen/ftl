# AGENTS.md: the fixture fleet

<!-- Written by `fleetl agents sync` from the fleet's metadata (host.nix,
service.nix, user.nix and mkFlake's arguments). Edit those, not this
file: the fleet-agents check fails while it is stale. -->

This repository is the NixOS fleet **fixture**, laid out
for ftl: `ftl.lib.mkFlake` in `flake.nix` turns every folder into flake
outputs. Every host also carries its own part of this file as
`/etc/AGENTS.md`, with what its configuration adds.

## Layout

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
  reference as `static.<name>`.

## Working here

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
  next deployment.

## Hosts

| host | system | importance | services | layers | users | hardware key |
| --- | --- | --- | --- | --- | --- | --- |
| `alpha` | x86_64-linux | required | `mesh`, `web` | `tools`, `svc` | `alice`, `bob` | none registered |
| `beta` | aarch64-linux | optional | `mesh` | `tools` | `alice` | headless |
| `gamma` | x86_64-linux | required | `mesh` | `tools` | `alice` | none registered |

A `required` host that fails to build blocks the update of the fleet, an
`optional` one does not, and an `ignored` one is not built.

Layers are installed and rolled back on a host with `ftl-layers update |
list | rollback <layer>`, never with `nix-env`.

## Hardware keys

Keys are used for SSH logins, sudo, commit signing and, on build hosts,
signing the binary cache. On an **attended** host a person is there to
touch the key when asked; on a **headless** one nobody is, and its key
works without touch. Hosts without registered readers leave smartcards
alone.

- `beta` (headless): `builder` (USB 1050:0407, port 1-4)

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
  outstanding", or a card that seems gone, usually means this.
- Signing a commit, pushing, or connecting to a host may need the user's
  key, and so their PIN or touch: say so before starting, run it in the
  foreground, and do not retry a failed signature on your own.
- **Only registered readers exist.** pcscd ignores every USB reader not
  registered for the host (udev `PCSCLITE_IGNORE`), so gpg, OpenSC and
  ykman's smartcard interface do not see them either. A card that does not
  show up is unregistered or unplugged: register it (`smartcard.readers` in
  `host.nix`, or mkFlake's `smartcard` for every host) instead of working
  around the filter. Only the smartcard (CCID) interface is filtered; FIDO2,
  U2F and OTP are not.

### On headless hosts

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
  safe.

## Binary caches

- http://alpha.example.org:8080/cache, served by `alpha`, signed by `ftl-test-1:6CA2VCkcTQDS8JL6HcoXOOHZWCqjV+3baLKM86c7dcw=`

## Services

| service | hosts | layers |
| --- | --- | --- |
| `mesh` | hub: `alpha`; spoke: `beta`, `gamma` | `tools` |
| `web` | `alpha` | - |

## Users

| user | admin | hosts | services |
| --- | --- | --- | --- |
| `alice` | yes | all | - |
| `bob` | no | `alpha` | `web` |

Accounts are key-only. sudo authenticates against the SSH agent the user
forwards (pam_rssh): it fails without one, and with a touch-policy key it
needs a touch.

The hosts' Nix daemons trust nobody but root (unless a host sets
`fleet.nix.trustWheel`). Closures the fleet's builder built carry the
cache's signature and copy as they are. One built elsewhere is pushed
through sudo first, which needs the forwarded agent (and a touch):

```
nix copy --no-check-sigs --to 'ssh-ng://<host>?remote-program=sudo%20nix-daemon' <path>
```

`nixos-rebuild --target-host <host> --sudo` or deploy-rs then find the
paths in place.
