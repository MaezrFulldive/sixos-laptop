# sixos on a laptop: ly + mango, no dual-boot

[![Test](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/test.yml/badge.svg)](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/test.yml)
[![Update pins](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/update.yml/badge.svg)](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/update.yml)

Step-by-step instructions, and everything they need, for installing
[sixos](https://codeberg.org/amjoseph/sixos) (a Nix-based OS that uses s6
instead of systemd) as the **only** operating system on a laptop.

What you end up with:

- **ly** login screen on tty1 that starts the **mango** Wayland compositor,
  with what mango's defaults expect: foot, rofi, sound (PipeWire),
  screenshots, clipboard history, portals, a keyring (or no desktop at all)
- optionally **qutebrowser**, with mpv, yt-dlp, GStreamer, spell checking
  and its PDF viewer
- **NetworkManager** (`nmtui`) for Wi-Fi and wired networks, and enough tools
  to repair the system from its own console: vim, git, curl, ssh, w3m, disk
  tools
- password-protected `doas`, and a password-protected root login on tty2 for
  rescue
- a **prebuilt** kernel and firmware from NixOS (no kernel compiling)
- GRUB (UEFI) with a "sixos" and a "sixos (fallback)" entry
- s6 / s6-rc as the init system, zram swap

## How this repository stays up to date

Every URL, revision and hash lives in [`pins.json`](pins.json), never in
these instructions, so you never paste a hash by hand. Currently pinned:

<!-- pins:begin -->
| what | from | pinned revision |
| ---- | ---- | --------------- |
| sixos | [codeberg.org/amjoseph/sixos](https://codeberg.org/amjoseph/sixos) `master` | [`26c564b4b4c1`](https://codeberg.org/amjoseph/sixos/commit/26c564b4b4c1957259b065636e71f4ef87da0295) |
| kernel, firmware, ly, mango, desktop | nixpkgs `nixos-26.05` | [`0dc498bfe49b`](https://github.com/NixOS/nixpkgs/commit/0dc498bfe49baeb18b0f9891e800b53bb2603193) |
| base system (s6, busybox, doas, nix) | nixpkgs, as pinned by sixos | [`38edd08881ce`](https://github.com/NixOS/nixpkgs/commit/38edd08881ce4dc24056eec173b43587a93c990f) |
<!-- pins:end -->

- **Every Monday** the [update workflow](.github/workflows/update.yml) moves
  the pins to the newest sixos commit and the newest commit of the NixOS
  release, then runs the full test. It pushes the update (and this table) to
  `main` **only if the test passes**; otherwise it opens an issue and `main`
  keeps the last working versions. When a new NixOS release comes out, it
  opens a pull request for you to review instead of switching on its own.
- **Every push and pull request** runs the [test workflow](.github/workflows/test.yml).
  The same test runs locally with `nix-build tests -A all`.
  It builds the laptop configuration, then runs the install command
  ([`scripts/install-on-live-usb`](scripts/install-on-live-usb)) inside a VM
  twice: onto an empty disk, then again reusing that disk. It boots the
  result with UEFI, an NVMe drive and a network card, the way a laptop does,
  and checks the following ([details](tests/default.nix)):
  - the system boots to a login prompt
  - passwords work for root and the user, and survive the reinstall
  - `doas` asks for a password and rejects a wrong one
  - NetworkManager gets an address by DHCP and has the Wi-Fi networks
  - logging in through ly starts mango (a screenshot is saved), with sound,
    portals, the keyring and the clipboard history working
  - `poweroff` powers off instead of rebooting

  It also checks every link in this README.
- The changes this setup needs in sixos are kept as small patches in
  [`patches/sixos/`](patches/sixos) and applied to the pinned upstream sixos at
  build time. If upstream changes so much that one stops applying, the test
  fails and nothing is updated.

---

## 0. Before you start

Everything happens on the laptop itself, booted from a **NixOS live USB**.
The live USB already has `nix`; you only use it for the install and don't
install NixOS. sixos becomes the only system on the disk.

- **UEFI only.** Turn off **Secure Boot** in the laptop's firmware settings.
  The kernel and GRUB are not signed.
- **Internet access** is needed during the install (about 2 GB, 3 GB with
  qutebrowser, downloaded from cache.nixos.org straight onto the laptop's
  disk).
- **Almost nothing is compiled.** The kernel, firmware, nix, mesa, ly, mango
  and the programs come prebuilt. Only a few small packages that sixos
  patches (busybox, s6-rc, s6-linux-init, abduco, alsa-utils,
  mdev-like-a-boss) are compiled, which takes a few minutes.
- **Reinstalling?** If the disk already has sixos on it (also an install
  that stopped halfway), the installer offers to **reuse** it: it keeps the
  Nix store (nothing is downloaded or compiled twice), `/home`, the
  passwords and the Wi-Fi networks, and replaces the rest.
- **Not included yet:** disk encryption, a screen locker, Bluetooth, and
  sshd (`sshd = true` in the host file adds it).

---

## 1. Boot the live USB and connect

1. Download a **NixOS ISO** from <https://nixos.org/download/>. The
   graphical one makes Wi-Fi easy (and the installer takes the network you
   connect to over to the new system); the **minimal** one is much smaller.
   Write it to a USB stick from any Linux computer (check `/dev/sdX` with
   `lsblk` first; everything on it is erased):
   `sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
2. Boot the laptop from it and connect to the internet. Ethernet or USB
   tethering from a phone needs no setup. Wi-Fi: the network icon on the
   graphical ISO; on the minimal one, see
   [networking in the NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installation-manual-networking).

---

## 2. Get this repository

Open a terminal on the live USB:

```sh
nix-shell -p git --run 'git clone https://github.com/MaezrFulldive/sixos-laptop.git'
cd sixos-laptop
```

---

## 3. Install

```sh
sudo ./scripts/install-on-live-usb
```

It asks, with the answer in `[brackets]` taken when you press Enter:

| question | |
| --- | --- |
| which disk | the live USB itself isn't offered |
| reuse the sixos already on it? | only asked if there is one |
| host name | `laptop`; also the name of your settings file, `site/hosts/laptop.nix` |
| your user name | |
| install the desktop? | ly + mango and its programs; "no" gives a text console |
| install qutebrowser? | with mpv, yt-dlp, GStreamer, spell checking |
| Wi-Fi networks | the ones the live USB is connected to are offered; add more by name |

It writes your answers to `site/hosts/<host>.nix` (it detects the disk's
drivers itself), shows a summary, and asks you to type `erase` before
touching the disk. Then it asks for **your password** (ly and doas) and the
**root password** (the rescue console on tty2; Enter = the same as yours),
and runs on its own:

1. partitions the disk (a 1 GiB EFI partition `ESP` and an ext4 root
   `sixos`), or, reusing it, cleans out everything but the Nix store,
   `/home` and `/root`
2. writes `/etc/shadow`, the Wi-Fi networks and ssh host keys, and copies
   this repository to `~/sixos-laptop` on the new disk
3. builds the system **directly into the disk's `/nix/store`**, so the
   downloads land on the disk, not in the live USB's memory
4. copies the kernel and initrd to the ESP and installs GRUB (also at the
   fallback path `EFI/BOOT/BOOTX64.EFI`, so it boots even if the firmware
   forgets the boot entry)

**If it stops** (the network dropped, ...), fix the cause and run it again:
answer "yes" to reusing the disk, and it continues with everything it
already downloaded.

When it says it's done, type `reboot` and remove the USB stick.
`./scripts/install-on-live-usb --help` lists a flag for every question.

---

## 4. First boot

1. GRUB shows "sixos". Let it boot.
2. Boot messages go to tty2, so tty1 stays blank until ly appears.
3. **ly on tty1**: your user is already selected and the cursor is in the
   password field, so type your password and press Enter. Mango is the only
   session. (To pick a different user, move up to the login field and use
   Left/Right; ly's login field is a list, not a text box.)
4. **mango**:

   | keys | |
   | --- | --- |
   | `Alt+Return` | foot terminal |
   | `Alt+Space` | rofi launcher |
   | `Alt+Q` | close a window |
   | `Print` | screenshot of an area, to annotate in satty (saved to `~/Pictures/Screenshots`) |
   | `Shift+Print` | the whole screen, to the clipboard |
   | `Super+V` | clipboard history |
   | volume and brightness keys | work |
   | `Super+M` | quit mango and go back to ly |

   To customize it, run
   `mkdir -p ~/.config/mango && cp /etc/mango/config.conf ~/.config/mango/`
   and edit the copy. Keep its last line, `source=/etc/mango/sixos.conf`:
   that's where the screenshot, clipboard and media keys come from.
5. **tty2** (Ctrl+Alt+F2) has the boot log and a `login:` prompt for root.
   Without the desktop, that prompt is on tty1.

**Your configuration** is the copy of this repository in **`~/sixos-laptop`**
(there is no `/etc/nixos`). This machine's settings are in
`~/sixos-laptop/site/hosts/<host>.nix`; after changing them:

```sh
sixos-rebuild switch          # build, switch to it, and boot it from now on
```

Commit your host file (`git add site/hosts; git commit`), so `git pull`
merges the weekly updates into it.

Useful commands:

```sh
nmtui                         # Wi-Fi and other networks
doas s6-rc -a list            # services that are up
ls /var/log/                  # one log directory per service
doas /run/init/bin/poweroff   # shut down   (reboot: /run/init/bin/reboot)
```

**Next: [docs/](docs/README.md)** explains how to configure and use the
system: adding programs, services, several machines, and how sixos differs
from NixOS (infusions instead of modules, s6 instead of systemd).

---

## 5. Updating later

Pull the latest tested pins, then rebuild:

```sh
cd ~/sixos-laptop
git pull
sixos-rebuild switch
```

`switch` switches the running system to the new one, restarting only the
services that changed. It also makes the new system the default for the
next boot: it copies the kernel and initrd to the ESP and keeps the previous
system as **"sixos (fallback)"** in GRUB.

> ⚠️ If an update changes ly (its package or settings, which most NixOS
> updates do), `switch` restarts ly, which **ends your mango session**.
> Save your work first, or run `sixos-rebuild boot` instead and reboot.

`sixos-rebuild --help` shows the others: `boot`, `test`, `build`,
`dry-activate`.

**From another computer, pushing to the laptop** (needs `sshd = true` in the
host file, and the other computer's key in the laptop's
`/root/.ssh/authorized_keys`; the installer's `--ssh-key` puts it there):

```sh
cd ~/sixos-laptop
nix-build -A hosts.laptop.configuration
nix copy --no-check-sigs --to ssh://root@LAPTOP_IP ./result
ssh root@LAPTOP_IP "$(readlink -f result)/bin/deploy"
```

---

## Troubleshooting

**The installer stopped**
Run it again and reuse the disk: it continues with what it already
downloaded. "no internet connection": connect first (step 1). "has an
error" after writing the host file: the message above it names the line;
fix `site/hosts/<host>.nix` and run it again. If the live USB itself runs
out of memory, it's before the disk was touched: use the minimal ISO, which
leaves more memory free.

**`nix-build` error: "host contains unknown top-level attrNames: ..."**
A typo in `site/hosts/laptop.nix` or `nix/laptop.nix`. The allowed keys are in
sixos's `types/default.nix` under `host-fields`.

**The firmware doesn't show a "sixos" boot entry**
Choose "UEFI: <your disk>" in the firmware's boot menu. The installer also
put GRUB at the fallback path, which every UEFI firmware tries.

**Boot drops into a `/bin/sh` prompt in the initrd**
The initrd couldn't mount the root filesystem. At that prompt:

```sh
ls /dev/nvme* /dev/sd*         # is the disk there? If not: root-disk-modules
blkid                          # is there a filesystem with LABEL="sixos"?
modprobe nvme                  # try loading the driver by hand
mount -o ro LABEL=sixos /root
exec /early/finish             # continue booting
```

**ly is only partly drawn (parts appear only when they change)**
The GPU driver took over the screen after ly had drawn it. ly waits up to 15
seconds for a GPU driver (i915, amdgpu, nouveau...) before starting; if
yours loads later or not at all, `dmesg | grep -i drm` shows what happened.
Restarting ly redraws it: log in as root on tty2 and run
`s6-svc -r /run/service/ly`.

**tty1 stays blank (no ly)**
Switch to tty2 (Ctrl+Alt+F2), log in as root, and check
`s6-rc -a list | grep -e ly -e seatd -e run-user` and
`tail /var/log/ly/current`. Start ly by hand with `s6-rc -u change ly`.

**ly says the login failed although the password is right**
`ls -l /etc/pam.d/` must list `ly`, `doas` and `other`. `/etc/shadow` must
contain a `$6$...` hash for your user and be mode 600.

**mango starts and exits immediately (you're back in ly)**
Read `~/ly-session.log` and `/var/log/ly.log`. A wrong command in
`session-commands` doesn't stop mango, but a broken `~/.config/mango/config.conf`
does. Then check that
`/run/user/1000` exists, that `/run/seatd.sock` exists, and that `id` lists
`_video`. To see mango's own errors, log in on tty2 as your user and run
`XDG_RUNTIME_DIR=/run/user/1000 mango-session`.

**`doas: Authentication failed` / `doas: not permitted`**
You must be in `wheel` (`id`) and type *your* password. The password check
also needs the `pam-helpers` service (`ls -l /run/wrappers/bin/unix_chkpwd`
should show a setuid file). If `doas` itself is broken, log in as root on
tty2.

**Root's password is rejected on tty2 ("Login incorrect")**
`/etc/securetty` must exist (the installer writes it). Without it, busybox
`login` rejects root's correct password.

**No network / Wi-Fi doesn't connect**
`nmcli device` lists the network devices. If the Wi-Fi card is missing,
`dmesg | grep -i firmware` shows whether its firmware failed to load. If it
is "unavailable", check `rfkill` (a Wi-Fi key or switch). NetworkManager's
log: `tail /var/log/networkmanager/current`.

**No sound**
`wpctl status` lists the devices; `pidof pipewire wireplumber pipewire-pulse`
should print three numbers (they start with your session). `id` must list
`_audio`. Their messages are in `~/ly-session.log`.

**Screenshots, screen sharing or file pickers don't work**
They go through the portals, which start on demand: `pidof xdg-desktop-portal`
after trying. If you copied mango's config, check that it still ends with
`source=/etc/mango/sixos.conf`. Errors are in `~/ly-session.log`.

**A system that won't boot at all**
Pick "sixos (fallback)" in GRUB. If that fails too, boot the live USB, then
`mount /dev/disk/by-label/sixos /mnt` and point
`/mnt/nix/var/nix/profiles/nextboot` at an older `nextboot-N-link`.

**GRUB has no password**
Anyone at the keyboard can add kernel parameters such as `init=/bin/sh`. If
that matters, set a GRUB password (`grub-mkpasswd-pbkdf2`, then
`set superusers` and `password_pbkdf2` in `/boot/grub/grub.cfg` on the ESP).

---

## What's in this repository

| path | what it is |
| --- | --- |
| [`site/hosts/laptop.nix`](site/hosts/laptop.nix) | **your** settings (the installer writes this file) |
| [`nix/laptop.nix`](nix/laptop.nix) | the system configuration: network, rescue tools, doas, PAM, kernel, services |
| [`nix/desktop.nix`](nix/desktop.nix) | the desktop: mango's session, its programs and key bindings, qutebrowser |
| [`docs/`](docs/README.md) | how to configure and use the installed system |
| [`by-name/`](by-name) | services of this repository: NetworkManager, the D-Bus system bus, ... ([docs/services.md](docs/services.md)) |
| [`pins.json`](pins.json) | every upstream source, updated weekly |
| [`patches/sixos/`](patches/sixos) | changes to upstream sixos (below) |
| [`scripts/install-on-live-usb`](scripts/install-on-live-usb) | the install command from step 3 |
| [`installer/sixos-install.sh`](installer/sixos-install.sh) | the part of it that partitions, writes `/etc` and installs GRUB |
| [`tests/`](tests) | the VM test; run it yourself with `nix-build tests -A all` |
| [`scripts/update-pins.py`](scripts/update-pins.py) | what the weekly update runs |

The patches to sixos:

1. `0001`: a `boot.console-autologin` option. Upstream gives a root shell
   with no password on the console; with `false` it asks for a user name and
   password.
2. `0002`: the x86 tag only changes the kernel config of sixos's own kernel,
   so a stock NixOS kernel comes prebuilt from the binary cache instead of
   being recompiled.
3. `0003`: `poweroff` no longer reboots (the shutdown script ended with a
   forced `reboot`).
4. `0004`: the `ly-dm` service (the ly display manager). It waits for the
   GPU driver before drawing, so the driver taking over the screen doesn't
   leave ly half-drawn.
5. `0005`: downloads `mdev-like-a-boss` from a mirror. Its original GitHub
   repository was deleted, which breaks every sixos build; the hash pins the
   exact same contents.

## Further reading

- sixos: <https://codeberg.org/amjoseph/sixos>, including `doc/README.md`
- Talk: <https://media.ccc.de/v/38c3-sixos-a-nix-os-without-systemd>
- mango: <https://github.com/DreamMaoMao/mangowc>
- ly: <https://codeberg.org/fairyglade/ly>
