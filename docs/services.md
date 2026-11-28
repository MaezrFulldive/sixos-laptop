# Services, and what to do without systemd

Most programs don't care about the init system. The ones that do usually
want one of these:

- to be started at boot and kept running: write a service (below)
- to run while you're logged in (notifications, a bar): `session-commands`
- something systemd normally provides (logind, udev, D-Bus, a user
  manager, timers): see [the table](#what-systemd-would-have-provided)

None of this needs anything unusual: a service is a short Nix function that
says which command to run.

## A service of your own

Services live in `by-name/<first two letters>/<name>/service.nix`, in this
repository (sixos's own are in [its `by-name/`](https://codeberg.org/amjoseph/sixos/src/branch/master/by-name),
look there first). A complete example, [`by-name/ea/earlyoom/service.nix`](../by-name/ea/earlyoom/service.nix):

```nix
# arguments sixos fills in, then the settings you may pass
{ pkgs, six, targets
, package ? pkgs.earlyoom
, min-free-percent ? 5
, extra-args ? [ ]
}:

six.mkFunnel {                      # a long-running, supervised process
  run.argv = [
    "${package}/bin/earlyoom"
    "-m" (toString min-free-percent)
    "-s" (toString min-free-percent)
  ] ++ extra-args;

  passthru.after = [ targets.mounts.proc ];   # start after /proc is mounted
}
```

Turn it on in `site/hosts/<machine>.nix`:

```nix
  extra-config = host: {
    targets.earlyoom.__assign = host.services.earlyoom { min-free-percent = 10; };
  };
```

After `deploy`, it is running (`doas s6-svstat /run/service/earlyoom`), it
starts at every boot, and its output is in `/var/log/earlyoom/current`.

The arguments a service function can ask for: `pkgs` (the base nixpkgs;
desktop programs are better taken from `(import ../../../nix/sources.nix).desktop-pkgs`),
`six` (the constructors below), `targets` (other services, for `after`),
`services`, `host` (the whole machine, e.g. `host.users.me.uid`), `lib`.

### `six.mkFunnel`: long-running programs

| argument | meaning | systemd |
| --- | --- | --- |
| `run.argv = [ ... ]` | the command; it must **stay in the foreground** | `ExecStart=` + `Type=simple` |
| `run = pkgs.writeScript "run" "#!${pkgs.runtimeShell}\n..."` | or a script that ends in `exec program` | |
| `user = "me"; group = "me";` | run as this user (default root) | `User=`, `Group=` |
| `extra-groups = [ "_video" ];` | additional groups | `SupplementaryGroups=` |
| `env = { FOO = "bar"; };` | environment (it starts out **empty**: set `PATH`, `HOME` yourself if the program needs them) | `Environment=` |
| `mkdir = { "/var/lib/foo" = "0700"; };` | directories made (owned by `user`) before starting | `StateDirectory=`, `RuntimeDirectory=` |
| `run.chdir = "/var/lib/foo";` | working directory | `WorkingDirectory=` |
| `finish = ...;` | runs after the program exits; must never fail | `ExecStopPost=` |
| `notification-fd = 3;` | the program reports readiness by writing a newline to fd 3 | `Type=notify` (for s6-aware programs) |
| `passthru.after = [ targets.foo ];` | start after foo is up, stop before it goes down | `After=` + `Requires=` |

Restarting a program that exits is automatic (that's what s6 is for):
there's no `Restart=` to set. Programs that daemonize (fork into the
background) can't be supervised. Almost all of them have a flag to stay in
the foreground: `-f`, `-n`, `--foreground`, `--nodaemon`, `-D`.

### `six.mkOneshot`: run once at boot

For things that aren't a process: setting a value in `/sys`, making a
directory, loading a module. Example: stop charging the battery at 80%
(on laptops that support it):

```nix
  extra-config = host: {
    targets.battery-limit.__assign = host.six.mkOneshot {
      up = host.pkgs.writeScript "battery-limit" ''
        #!${host.pkgs.runtimeShell}
        echo 80 > /sys/class/power_supply/BAT0/charge_control_end_threshold || true
      '';
    };
  };
```

A oneshot can also live in `by-name/` like the earlyoom example, if several
machines use it. Make sure **oneshots never fail** (note the `|| true`): a
failing oneshot stops s6-rc, and everything after it doesn't start.

### Something every N minutes

There's no cron and no timers. A long-running loop does the same job, and
s6 restarts it if it crashes:

```nix
    targets.backup.__assign = host.six.mkFunnel {
      run = host.pkgs.writeScript "backup" ''
        #!${host.pkgs.runtimeShell}
        while true; do
          ${host.pkgs.rsync}/bin/rsync -a /home/me/Documents/ /mnt/backup/ || echo "backup failed"
          ${host.pkgs.coreutils}/bin/sleep 3600
        done
      '';
    };
```

## Programs that run with your session

`systemd --user` doesn't exist. Programs that should run while you're logged
in go in `session-commands` in `site/hosts/<machine>.nix`; the programs
themselves go in `extra-packages`:

```nix
  extra-packages = pkgs: with pkgs; [ mako waybar ];
  session-commands = [ "mako" "waybar" ];
```

When you log in, ly starts `mango-session` (in `nix/desktop.nix`), which:

1. sets the session's environment (`XDG_DATA_DIRS`, so launchers find
   `.desktop` files and icons; `XDG_CURRENT_DESKTOP`, for the portals; ...)
2. starts a **D-Bus session bus** (`dbus-run-session`), so
   `DBUS_SESSION_BUS_ADDRESS` is set for everything in the session, and
   portals and the keyring can start on demand
3. starts sound: PipeWire, then WirePlumber and pipewire-pulse
4. starts each `session-commands` entry in the background, as you
5. runs mango
6. stops all of them when mango exits

mango's own `exec-once=` lines in `~/.config/mango/config.conf` work too,
for things that belong to mango (wallpaper, mango-specific tools). They
aren't stopped when mango exits, and changing them needs no rebuild.

Session programs log to `~/ly-session.log` (ly's session log), if anywhere.

## What systemd would have provided

| programs expect | here | what to do |
| --- | --- | --- |
| **logind** (seats, access to the GPU and input) | **seatd**; you're in `_video` and `_input` | Programs using libseat (wlroots compositors, mango) work. Programs that talk to logind over D-Bus only (GNOME, KDE Plasma, some screen lockers and Steam's session features) don't. |
| **`/run/user/<uid>`** | created at boot by the `run-user` target; ly sets `XDG_RUNTIME_DIR` | nothing |
| **udev** (`libudev`) | **mdevd**, plus **libudev-zero** put first via `LD_LIBRARY_PATH` | Everything started from mango inherits it. A *service* that enumerates devices (input, game controllers) needs `env.LD_LIBRARY_PATH = "${desktop-pkgs.libudev-zero}/lib";`. udev *rules* files don't apply; device permissions come from sixos's mdevd config (`_video`, `_input`, `_audio` groups). |
| **D-Bus session bus** | started for each session by `mango-session` | nothing |
| **D-Bus system bus** | the `dbus` service ([`by-name/db/dbus-system`](../by-name/db/dbus-system/service.nix)), without bus activation | A program that offers a system service (bluez, upower, udisks) needs: its package in the bus's `packages` (that loads its D-Bus policy), and an s6 service of its own that runs it, `after` the bus. NetworkManager and wpa_supplicant are set up exactly that way in `nix/laptop.nix`. |
| **polkit** | none | `doas`. NetworkManager lets local users change the network without asking (`auth-polkit = false`). |
| **`systemd --user`** | `session-commands` | above |
| **timers / cron** | none | a long-running loop (above) |
| **journald** | per-service logs in `/var/log/<name>/`; `/dev/log` goes to the `syslog` service (`/var/log/syslog/`) | `s6-tai64nlocal < /var/log/NAME/current` |
| **tmpfiles.d** | none | `mkdir = { ... };` in the service, or a oneshot |
| **https certificates** (`/etc/ssl`, `SSL_CERT_FILE`) | Mozilla's list from `cacert`, in `/etc/ssl` and `$SSL_CERT_FILE`, as on NixOS | nothing |
| **resolved** | NetworkManager writes each network's DNS servers to `/etc/resolv.conf` | nothing |
| **NetworkManager** | NetworkManager, with wpa_supplicant and libudev-zero ([`by-name/ne/networkmanager`](../by-name/ne/networkmanager/service.nix)) | `nmtui`; [configuring.md](configuring.md#network-and-wi-fi). No dispatcher scripts, no VPN plugins. |
| **`/usr/bin/foo`**, FHS paths | only `/bin/sh` and `/usr/bin/env` exist, as on NixOS | Same answers as on NixOS: `steam-run` or `buildFHSEnv` for prebuilt binaries, `appimage-run` for AppImages. |
| **`sudo`** | `doas` | `doas`, or alias `sudo=doas` |
| **`shutdown`, `reboot`** | `/run/init/bin/poweroff`, `/run/init/bin/reboot` | ly's F1/F2 also work |

## When a program still won't start

1. Run it from a terminal in mango first: its error message usually names
   what it's missing (a D-Bus service, a device, a file under `/usr`).
2. For a service: `s6-tai64nlocal < /var/log/NAME/current`. If there's
   nothing, run the service's command by hand as the same user
   (`cat /run/service/NAME/run` shows exactly what s6 runs).
3. "Cannot connect to the D-Bus system bus" or "logind": see the table
   above; the program needs one of the missing pieces, not a rebuild.
4. Look at the NixOS module for the program (search
   <https://search.nixos.org/options>): it shows which users, groups,
   directories and environment the program needs, which is what your
   `service.nix` has to provide.
