# Configuring this machine

## Where things are

The installer copied this repository to `~/sixos-laptop`. Everything about
the system is in it:

| file | what's in it |
| --- | --- |
| `site/hosts/laptop.nix` | **this machine's settings**: user name, Wi-Fi card, extra programs, session programs, extra services. The file name is the host name. |
| `nix/laptop.nix` | the setup every machine here shares: ly, mango, doas, PAM, kernel, the base services. Each `CHANGE ME`-style setting in the host file is an argument at its top. |
| `by-name/` | services of your own ([services.md](services.md)) |
| `site/overlay.nix` | settings for *every* machine at once ([multiple-machines.md](multiple-machines.md)) |
| `pins.json` | which sixos and nixpkgs are used; updated weekly upstream |
| `patches/sixos/` | the changes this setup makes to sixos |

There is no `/etc/nixos`, no channel and no `nixos-rebuild`. The system is
whatever `nix-build` builds from this directory.

## Change something, then switch to it

```sh
cd ~/sixos-laptop
vi site/hosts/laptop.nix                  # (busybox vi; add a nicer editor below)
nix-build -A hosts.laptop.configuration   # as your user, no doas needed
doas ./result/bin/deploy
```

`deploy` = `activate` (switch the running system, restarting only the
services whose configuration changed) + `nextboot` (copy the kernel and
initrd to the EFI partition and make this the system GRUB boots).
The other commands in `./result/bin/`:

| command | does |
| --- | --- |
| `dry-activate` | shows which services would start, stop or restart |
| `activate` | switches the running system only; a reboot goes back |
| `nextboot` | only sets what boots next time |

If a change breaks booting, pick **"sixos (fallback)"** in GRUB: it is the
system you booted before the last `deploy`.

If `deploy` would restart ly (most changes to ly or its settings do), your
mango session ends. Use `nextboot` and reboot instead if you have work open.

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

## mango (the desktop)

mango reads `~/.config/mango/config.conf`, or `/etc/mango/config.conf` if you
don't have one. To customize it:

```sh
mkdir -p ~/.config/mango && cp /etc/mango/config.conf ~/.config/mango/
```

Default keys: `Alt+Return` terminal (foot), `Alt+Space` launcher (rofi),
`Alt+Q` close window, `Super+M` quit mango (back to ly).

Programs that should run for as long as you're logged in (sound, a
notification daemon, a status bar) go in `session-commands` instead. See
[services.md](services.md#programs-that-run-with-your-session).

## Sound

Not on by default. To add it, put this in `site/hosts/laptop.nix`:

```nix
  extra-packages = pkgs: with pkgs; [ pipewire wireplumber pavucontrol ];
  session-commands = [ "pipewire" "wireplumber" "pipewire-pulse" ];
```

Then build and deploy, and log out and back in. Your user is in the `_audio`
group, which owns the sound devices.

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

## Wi-Fi

`eiwd` connects to the networks it has files for. There is no `iwctl`
(eiwd is iwd without D-Bus). To add a network:

```sh
doas sh -c 'printf "[Security]\nPassphrase=%s\n" "the passphrase" > "/etc/iwd/networks/My Network.psk"'
doas s6-svc -r /run/service/wifi
```

`man iwd.network` explains the file name rules (SSIDs with unusual
characters) and open networks (`.open` files).

## Files in /etc

`/etc/passwd`, `/etc/group`, `/etc/hosts`, `/etc/doas.conf` and
`/etc/profile` are links into `/run/current-system/etc/`, so they follow each
`deploy`. The rest of `/etc` is ordinary files you may edit.

To have the configuration manage another file, add it to
`extra-configuration-links` in `nix/laptop.nix`; it then appears in
`/run/current-system/etc/`. Link it into `/etc` once yourself
(`doas ln -s /run/current-system/etc/foo /etc/foo`); after that it follows
every `deploy`.

## Updating

```sh
cd ~/sixos-laptop
git pull                                  # the latest tested sixos and nixpkgs
nix-build -A hosts.laptop.configuration
doas ./result/bin/deploy
```

Keep your own changes committed on a branch of your own, so `git pull` can
merge the weekly updates into them.

To free disk space: `doas nix-collect-garbage`. It never removes the
current or the fallback system.
