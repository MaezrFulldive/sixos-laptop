# sixos for NixOS users

## The differences in one table

| NixOS | sixos |
| --- | --- |
| systemd | s6 (supervises processes) + s6-rc (dependencies) + s6-linux-init (pid 1) |
| the module system: `options`, `config`, `imports`, `mkIf`, `mkForce` | none. A machine is one plain attrset, changed with **infusions** (below) |
| `configuration.nix` | `site/hosts/<name>.nix` |
| `imports = [ ./foo.nix ]` | a list of infusions: `extra-config = host: [ (import ./foo.nix host) ]` ([multiple-machines.md](multiple-machines.md)) |
| `services.foo.enable = true` | `targets.foo.__assign = host.services.foo { ...settings... }` |
| `systemd.services.foo = { ... }` | a service file `by-name/fo/foo/service.nix` ([services.md](services.md)) |
| `environment.systemPackages` | `sw` (here: the `extra-packages` setting) |
| `environment.etc."foo".text` | `extra-configuration-links."etc/foo"` ([configuring.md](configuring.md#files-in-etc)) |
| `users.users.me` | `users.me` |
| `security.sudo` / polkit | `doas`, configured by `doas-conf` |
| logind | seatd (+ `/run/user/<uid>` made at boot) |
| udev | mdevd, with libudev-zero for programs that link libudev |
| journald / `journalctl -u foo` | `/var/log/foo/current`, one directory per service |
| `systemctl status/start/stop/restart foo` | `s6-svstat`, `s6-rc -u change`, `s6-rc -d change`, `s6-svc -r` ([table](configuring.md#services)) |
| `nixos-rebuild switch` / `boot` / `test` | `sixos-rebuild switch` / `boot` / `test` (a small script: `nix-build -A hosts.<name>.configuration && doas ./result/bin/deploy`) |
| `networking.networkmanager.enable` | always on here; `nmtui` |
| generations in the boot menu | "sixos" and "sixos (fallback)" (the previous one) |
| NixOS options search | the arguments at the top of each `service.nix`, and `nix/laptop.nix` |

There is no option documentation and no type checking of settings: a
service's settings are the arguments of its `service.nix` function, and a
misspelled argument is usually an error ("called with unexpected
argument"). sixos's
services are in `by-name/` of [sixos](https://codeberg.org/amjoseph/sixos/src/branch/master/by-name);
reading the one you use is the documentation.

## A machine is an attrset

In NixOS, modules declare options and the module system merges everything
together. In sixos, a machine ("host") is one big attrset, like a package
set: `pkgs`, `sw`, `users`, `targets`, `boot`, `services`, ... It is built
the way nixpkgs is built: by applying a list of overlays
`host-final: host-prev: { ... }`, each of which changes some attributes.
sixos supplies the first ones (defaults), your host file is one more, and
sixos finishes with a few that compute the system from the result.

`site/hosts/laptop.nix` is such an overlay. In this repository it is written
as a call to `nix/laptop.nix`, which returns the overlay:

```nix
args@{ laptop-host, ... }:
laptop-host args {          # settings in, `host-final: host-prev: ...` out
  username = "me";
  ...
}
```

- `host-prev` is the host *before* this overlay: what you're changing.
- `host-final` is the host *after all* overlays (lazy, like `final` in a
  nixpkgs overlay). Use it to refer to things: `host-final.services.seatd`,
  `host-final.targets.mounts.proc`, `host-final.pkgs.busybox`.

## Infusions instead of modules

An overlay has to return the *whole* changed attrset. Writing
`host-prev // { boot = host-prev.boot // { kernel = ... } }` by hand gets old
fast, so sixos uses [infuse](https://codeberg.org/amjoseph/infuse.nix):

```nix
infuse host-prev {
  boot.kernel.params.__append = [ "quiet" ];
  users.root.hashed-password.__assign = "x";
}
```

`infuse target infusion` walks the infusion like `recursiveUpdate`: nested
attribute names are paths into the target, and the leaves say what to do at
that path. The leaves are the double-underscore words ("sugars"):

| infusion | does | NixOS equivalent |
| --- | --- | --- |
| `x.__assign = v` | replace `x` with `v` (creating it if needed) | `x = mkForce v` |
| `x.__default = v` | set `x` to `v` only if it doesn't exist | `x = mkDefault v` |
| `x.__init = v` | create `x`; error if it already exists | (declaring it) |
| `x.__append = [ v ]` | add to the end of a list or string | `x = [ v ]` on a list option |
| `x.__prepend = [ v ]` | add to the front | `mkBefore` |
| `x.__input.arg.__assign = v` | `x.override { arg = v; }` (packages, buildEnv) | `package.override` |
| `x.__output.attr.__assign = v` | `x.overrideAttrs` (derivations) | `overrideAttrs` |
| `x.__overlay = final: prev: ...` | add an overlay to `x` (e.g. a package scope) | `nixpkgs.overlays` |
| `x.__values = f` | apply `f` to every attribute of `x` | |
| `x = old: new` | any function: called with the old value | |

A **list** of infusions is applied in order (later ones see what earlier
ones did). That's how `nix/laptop.nix` is built:

```nix
infuse host-prev ([
  { ... the base settings ... }
  { ... sshd on or off ... }
] ++ lib.optional desktop { targets.ly.__assign = ...; }
  ++ lib.toList (extra-config host-final))
```

What this means coming from modules:

- **No merging magic, no priorities.** Two `__assign`s to the same path:
  the later one wins, silently. Order is the only priority. Put
  machine-specific things after shared ones (`extra-config` comes last for
  that reason).
- **No `mkIf`**: use ordinary Nix (`lib.optional cond { ... }`,
  `if ... then ... else`, `lib.optionalAttrs`).
- **Plain values are errors.** `{ x = 3; }` as an infusion fails with
  `infuse.desugar: at path x: invalid type int`: say what to do with it,
  `x.__assign = 3`.
- **Removing** an attribute has no sugar; use a function:
  `targets = t: builtins.removeAttrs t [ "sshd" ];` (as `nix/laptop.nix`
  does), or assign `null` where the consumer accepts it.
- **Errors name the path** (`at path boot.kernel.params`), which is
  usually all you need.

## Services and targets

- A **service** is a function, one per file:
  `by-name/<first two letters>/<name>/service.nix`. sixos's are in its own
  `by-name/`; yours go in this repository's `by-name/`. On a host they're
  available, with their dependencies filled in, as `host.services.<name>`.
  A service does nothing until you make a target from it.
- A **target** is something s6-rc starts: a service called with its
  settings, stored under `targets.<name>`:

  ```nix
  targets.zram.__assign = host-final.services.zram { size-percent = 50; };
  ```

  The attribute name is what you use with `s6-rc` and what its log
  directory is called. One service can give several targets (two sshd on
  different ports). **Every top-level target is started at boot.**
- Ordering: a target's `passthru.after = [ host-final.targets.seatd ]` means
  "start after seatd is up, stop before it goes down", the same as systemd's
  `After=` + `Requires=`. There's only this one kind of dependency.
- `targets.global.coldplug`: up once devices in `/dev` exist (after
  mdevd's coldplug). `targets.mounts.""`: the root filesystem has been
  remounted read-write (`/etc` and `/var` are writable).

## s6 in two minutes

- **Long-running services** ("longruns") are supervised: if they exit, s6
  starts them again. They must stay in the foreground (no forking into the
  background; most daemons have a `-f`/`--foreground`/`-n` flag for this).
  Their output goes to their own logger, `/var/log/<name>/`.
- **Oneshots** are scripts that run once to bring something up (and
  optionally once to bring it down): mounting, setting sysctls, making
  directories.
- **A oneshot that fails stops s6-rc in its tracks**, and the services after
  it don't start. Make oneshot scripts that can't fail (`|| true` on
  anything optional).
- s6-rc reports a failed start to whoever asked (at boot: the boot log on
  tty2) and then forgets it. There's no "failed" state; read the log.
- Shutdown doesn't need service ordering: s6-linux-init stops everything,
  kills what's left and unmounts.

## How this repository fits around sixos

- `default.nix` calls sixos with `site/` (the hosts), this repository's
  `by-name/` (extra services), and a patched copy of upstream sixos
  (`patches/sixos/`).
- Two nixpkgs are in play. `host.pkgs` is the older nixpkgs sixos is
  pinned to; the base system (busybox, s6, nix, doas) comes from it, because
  sixos patches some of those. `desktop-pkgs` is a current NixOS release;
  the kernel, firmware, ly, mango and everything in `extra-packages` come
  from it, prebuilt.
