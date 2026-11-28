# Configuring this machine

## Where things are

The installer copied this repository to `~/sixos-laptop`. Everything about
the system is in it:

| file | what's in it |
| --- | --- |
| `site/hosts/laptop.nix` | **this machine's settings**: user name, desktop or not, qutebrowser, extra programs, session programs, extra services. The installer wrote it; the file name is the host name. |
| `nix/laptop.nix` | the setup every machine here shares: network, rescue tools, doas, PAM, kernel, the base services. Each setting in the host file is an argument at its top. |
| `nix/desktop.nix` | the desktop: mango's session, its programs and key bindings, qutebrowser |
| `by-name/` | services of your own ([services.md](services.md)) |
| `site/overlay.nix` | settings for *every* machine at once ([multiple-machines.md](multiple-machines.md)) |
| `pins.json` | which sixos and nixpkgs are used; updated weekly upstream |
| `patches/sixos/` | the changes this setup makes to sixos |

There is no `/etc/nixos`, no channel and no `nixos-rebuild`. The system is
whatever `nix-build` builds from this directory.

## Change something, then switch to it

```sh
cd ~/sixos-laptop
vim site/hosts/laptop.nix
sixos-rebuild switch
```

`sixos-rebuild` builds the configuration of this machine (the host whose
name the machine has) from `~/sixos-laptop`, as your user, then asks `doas`
for the last step:

| | does | the same by hand |
| --- | --- | --- |
| `switch` | switch the running system (restarting only the services whose configuration changed), and boot it from now on | `doas ./result/bin/deploy` |
| `boot` | boot it from the next boot on; the running system is untouched | `doas ./result/bin/nextboot` |
| `test` | switch the running system only; a reboot goes back | `doas ./result/bin/activate` |
| `dry-activate` | show which services would start, stop or restart | `doas ./result/bin/dry-activate` |
| `build` | only build it, as `./result` | `nix-build -A hosts.laptop.configuration` |

If a change breaks booting, pick **"sixos (fallback)"** in GRUB: it is the
system you booted before the last `switch`/`boot`.

If `switch` would restart ly (most changes to ly or its settings do), your
mango session ends. Use `boot` and reboot instead if you have work open.

## Programs

Add them to `extra-packages` in `site/hosts/laptop.nix`:

```nix
  extra-packages = pkgs: with pkgs; [ firefox helix mpv ];
```

`pkgs` is a current NixOS release (`nixos-26.05`). Search names on
<https://search.nixos.org/packages>. Programs end up in
`/run/current-system/sw/bin`, on everyone's `PATH`.

`nix-shell -p something` works too, for trying a program without installing
it. It uses this same nixpkgs only if you pass it:
`nix-shell -I nixpkgs=$(nix-instantiate --eval -E '(import ./nix/sources.nix).nixpkgs-desktop-path' | tr -d '"') -p mpv`.

**Unfree programs** (Steam, Discord, NVIDIA drivers ...) are refused until
you allow them. In `nix/sources.nix`, change the `desktop-pkgs` line
`config = { };` to `config = { allowUnfree = true; };`.

There is no home-manager. Your dotfiles are ordinary files in your home
directory.

## The desktop

`desktop = true` in the host file gives ly and mango, set up with the
programs mango's defaults are made for ([`nix/desktop.nix`](../nix/desktop.nix)):

| | | |
| --- | --- | --- |
| terminal | foot | `Alt+Return` |
| launcher | rofi | `Alt+Space` |
| screenshots | grim + slurp + wayfreeze, annotated in satty | `Print` (an area), `Shift+Print` (all, to the clipboard) |
| clipboard | wl-clipboard (`wl-copy`, `wl-paste`), wl-clip-persist, cliphist | `Super+V`: history |
| sound | PipeWire, WirePlumber, pipewire-pulse | volume keys; `wpctl status` |
| portals | xdg-desktop-portal with the wlr (screenshots, screen sharing) and gtk (file pickers) backends | |
| passwords for programs | gnome-keyring (it asks for a keyring password the first time a program stores one) | |
| brightness | brightnessctl | brightness keys |
| key and mouse events | wev | |

With `qutebrowser = true`, also qutebrowser (the default browser), mpv and
yt-dlp (videos), GStreamer and its plugins, hunspell dictionaries (in
qutebrowser: `:set spellcheck.languages '["en-US"]'`), pdf.js (PDFs open
in qutebrowser), xdg-utils and `certutil`.

mango reads `~/.config/mango/config.conf`, or `/etc/mango/config.conf` if you
don't have one. To customize it:

```sh
mkdir -p ~/.config/mango && cp /etc/mango/config.conf ~/.config/mango/
```

The copy ends with `source=/etc/mango/sixos.conf`: keep that line, it adds
the bindings and the clipboard programs above (and keeps them up to date).

Programs that should run for as long as you're logged in (a notification
daemon, a status bar) go in `session-commands`; sound is always started.
See [services.md](services.md#programs-that-run-with-your-session).

`desktop = false` leaves all of this out: the machine boots to a text login
on tty1, with the network and the rescue tools.

## Services

Services are started at boot by s6-rc. Every long-running service has a log
in `/var/log/<name>/current`.

| task | command |
| --- | --- |
| list running services | `doas s6-rc -a list` |
| list all services | `doas s6-rc-db list all` |
| start a service (and what it needs) | `doas s6-rc -u change NAME` |
| stop it (and what needs it) | `doas s6-rc -d change NAME` |
| restart a long-running one | `doas s6-svc -r /run/service/NAME` |
| is it running, since when | `doas s6-svstat /run/service/NAME` |
| read its log, with readable times | `s6-tai64nlocal < /var/log/NAME/current` |
| follow its log | `tail -f /var/log/NAME/current` |

A service that crashes is restarted automatically (about once a second). A
service that *fails to start* is reported once and left alone; s6-rc has no
"failed" state to look at later, so check the log.

To add services, see [services.md](services.md).

## Users and passwords

Users are defined in `nix/laptop.nix` (`users.${username}`), the password
hashes live only in `/etc/shadow`. To change a password:

```sh
HASH=$(mkpasswd -m sha512)                            # asks for the new password
doas sed -i "s|^me:[^:]*:|me:$HASH:|" /etc/shadow     # `root` instead of `me` for root
```

New users are added the same way as yours in `nix/laptop.nix` (`/etc/passwd`
is generated from the configuration), then given a line in `/etc/shadow`.

## Network and Wi-Fi

NetworkManager handles Wi-Fi and wired networks:

```sh
nmtui                         # a menu: connect, edit networks
nmcli device wifi list        # networks in range
nmcli device wifi connect "My Network" --ask
```

No `doas` needed. The networks you connect to are saved in
`/etc/NetworkManager/system-connections/` and survive updates and
reinstalls that reuse the disk. Wired networks are configured by DHCP as
soon as a cable is plugged in.

Settings for NetworkManager itself: `networkmanager-settings` in the host
file (e.g. `{ main.dns = "none"; }`, `{ device."wifi.scan-rand-mac-address" = "no"; }`),
or files in `/etc/NetworkManager/conf.d/`, which need no rebuild
(`doas s6-svc -r /run/service/networkmanager` after a change).

## Tools for when something is broken

Installed on every machine, desktop or not, so the system can be repaired
from its own console without a second computer: `vim`, `nano`, `git`,
`curl`, `wget`, `ssh`/`scp`, `rsync`, `w3m` (a text web browser, e.g. for a
captive portal), `nmtui`/`nmcli`/`iw`, `htop`, `tmux`, `lsblk`, `parted`,
`gdisk`, `mkfs.ext4`/`mkfs.fat`, `efibootmgr`, `lspci`, `lsusb`, `file`,
`tree`, `jq`, `rg`, `ncdu`, `lsof`, `unzip`, `xz`, `zstd`.

The console login on tty2 (tty1 without the desktop) works even when ly or
mango don't. If the last update broke something, pick
**"sixos (fallback)"** in GRUB.

## Files in /etc

`/etc/passwd`, `/etc/group`, `/etc/hosts`, `/etc/doas.conf` and
`/etc/profile` are links into `/run/current-system/etc/`, so they follow each
`switch`. The rest of `/etc` is ordinary files you may edit.

To have the configuration manage another file, add it to
`extra-configuration-links` in `nix/laptop.nix`; it then appears in
`/run/current-system/etc/`. Link it into `/etc` once yourself
(`doas ln -s /run/current-system/etc/foo /etc/foo`); after that it follows
every `switch`.

## Updating

```sh
cd ~/sixos-laptop
git pull                                  # the latest tested sixos and nixpkgs
sixos-rebuild switch
```

Keep your own changes committed (`git add site/hosts; git commit`), so
`git pull` can merge the weekly updates into them.

To free disk space: `doas nix-collect-garbage`. It never removes the
current or the fallback system.
