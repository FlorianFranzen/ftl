# Why a deploy can fail on a mount, and what couples it

Found the hard way on 2026-10-22, deploying darwin in Denkmuskel/infra. Worth
writing down because the failure looks like a storage problem and is not one,
and because the coupling that causes it is a single line in
`modules/state.nix`.

## What happened

A deploy rolled back with one error:

```
restarting the following units: srv-git.mount, srv-homework.mount, srv-media.mount,
  sshd.service, var-lib-jellyfin.mount, var-lib-radarr.mount, var-lib-stalwart.mount, ...
Failed to restart srv-media.mount
⚠️ [activate] [WARN] De-activating due to error
❌ Deployment to node darwin failed, rolled back to previous generation
```

`srv-media.mount` was `active (mounted)` the whole time. The journal says what
actually failed:

```
Unmounting /srv/media...
umount: /srv/media: target is busy.
srv-media.mount: Mount process exited, code=exited, status=32/n/a
```

The holder was an interactive shell — a tmux pane on the host whose working
directory was inside `/srv/media`. Nothing was wrong with the dataset, the
unit, or the configuration being deployed. An unrelated change (a mail server
setting) was rolled back because a shell was parked in a directory.

## Why the mounts were restarted at all

The mount unit was **byte-identical** between the running system and the new
one, which is the first thing to check and the thing that makes this
counter-intuitive. It was restarted because of what had changed in the
*previous* generation: the entries' setup service was renamed
(`infra-apps.service` → `fleet-state.service`), and the mount units name it:

```nix
# modules/state.nix
systemd.mounts = lib.mapAttrsToList (
  _: entry:
  {
    where = entry.path;
    requires = [ "fleet-state.service" ];      # <- this
    after = [ "fleet-state.service" ];
    wantedBy = [ "local-fs.target" ];
  }
```

switch-to-configuration compares unit files key by key. For a `.mount` it
treats a change to `[Mount] Options=` as a reload, and **anything else as a
restart** — with no opt-out, and only two exceptions in the whole system
(`nixpkgs`, `switch-to-configuration-ng/src/main.rs`):

```rust
} else if unit.ends_with(".mount") {
    // Just restart the unit. We wouldn't have gotten into this subroutine if only `Options`
    // was changed, in which case the unit would be reloaded. The only exception is / and /nix
    // because it's very unlikely we can safely unmount them so we reload them instead.
    if unit == "-.mount" || unit == "nix.mount" {
```

And a mount cannot decline: `restartIfChanged` is defined in `serviceOptions`
in `nixos/lib/systemd-unit-options.nix`, not in `mountOptions`, so
`systemd.mounts` has no such knob. Checked, not assumed.

So the rule to hold on to: **every byte of a mount unit's text is a trigger for
an unmount on the next deploy.** Putting the setup service's name in there
means the name is part of that text, and a rename or a re-point unmounts every
data store on every host at once.

`requires` adds a second, independent coupling: deactivation propagates along
it, so stopping or restarting `fleet-state.service` by hand also pulls the
mounts down, with the same EBUSY if anything holds them.

## Two levers, and what each buys

**Move the ordering to the service side.** Nothing needs the service's name to
appear in the mount unit. `fleet-state.service` can carry
`before = [ "<entry>.mount" ... ]` and the ordering edge is identical, because
`Before=`/`After=` are symmetric. The mount unit's text then reduces to
`what`/`where`/`type`/`wantedBy`, which changes only when the storage actually
changes — and a rename of the setup service churns one service unit instead of
every mount on the host. This is the fix for the restart problem.

**Drop `requires` to `wants`.** This does not stop switch-to-configuration
restarting a changed mount, but it removes the stop propagation, so a later
`systemctl restart fleet-state.service` no longer tears the data stores down
under running services.

What `requires` buys today is that a mount is never attempted when setup
failed. That is worth less than it looks: if `fleet-state.service` has not
created the dataset or subvolume, the mount fails on its own merits anyway, and
it fails for that entry alone rather than taking the deploy with it. The
entries' *service* units are already loosely coupled the right way — they use
`unitConfig.RequiresMountsFor`, which expresses "this needs that path mounted"
without owning the mount's lifecycle.

Both changes are compatible, and together the mount unit stops depending on the
setup service's identity at all.

## Status: both levers applied

`modules/state.nix` now does both, in the commit that adds this note:
`fleet-state.service` is wanted by `local-fs.target` and ordered `Before=`
each entry's mount, and the mount units carry only `what`, `where`,
`type`, `options` and `wantedBy`. Restarting `fleet-state.service` leaves
the mounts alone (`tests/state.nix` checks the unit text and that a
restart keeps the entries mounted).

The cost is the one the analysis above accepts: a mount started by hand no
longer pulls the setup in, so on a host where `fleet-state.service` failed
(at boot, say) the mount fails for its entry alone until the service is
started again.

**The deploy that brings this change rewrites every mount unit once** (the
`Requires=`/`After=` lines go), so that one deploy unmounts every entry on
every host, with the failure mode described above. Do the checks below on
each host before it. After that, a mount unit changes only when its storage
does.

## Before a deploy that changes mount units

A deploy that changes a mount unit will unmount every data store, so it fails
if anything holds one. Before deploying a host whose state entries changed:

```
# on the host
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' | grep /srv
sudo fuser -vm /srv/media
```

A shell's working directory is the common case; a running script over the data
and a backup walk are the others. `systemctl stop` on the consuming services is
not enough, because the holder is usually not one of them — in this incident
Jellyfin, Stash and the \*arrs were all stopped before the unmount was
attempted and it still failed.

The rollback behaves correctly throughout: the host keeps serving from the
previous generation and the mount stays mounted. The cost is a failed deploy
and the delay, not an outage.
