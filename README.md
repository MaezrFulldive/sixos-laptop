# sixos on a laptop: ly + mango, no dual-boot

[![Test](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/test.yml/badge.svg)](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/test.yml)
[![Update pins](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/update.yml/badge.svg)](https://github.com/MaezrFulldive/sixos-laptop/actions/workflows/update.yml)

Step-by-step instructions, and everything they need, for installing
[sixos](https://codeberg.org/amjoseph/sixos) (a Nix-based OS that uses s6
instead of systemd) as the **only** operating system on a laptop.

What you end up with:

- **ly** login screen on tty1 that starts the **mango** Wayland compositor
- password-protected `doas`, and a password-protected root login on tty2 for
  rescue
- a **prebuilt** kernel and firmware from NixOS (no kernel compiling)
- GRUB (UEFI) with a "sixos" and a "sixos (fallback)" entry
- s6 / s6-rc as the init system, Wi-Fi through `eiwd`, zram swap

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
  It builds the laptop configuration, then runs the over-ssh install command
  ([`scripts/install-over-ssh`](scripts/install-over-ssh), which runs the same
  [`installer/sixos-install.sh`](installer/sixos-install.sh) as the live-USB
  install) inside a VM onto an empty disk.
  It boots that disk with UEFI and an NVMe drive, the way a laptop does, and
  checks the following ([details](tests/default.nix)):
  - the system boots to a login prompt
  - passwords work for root and the user
  - `doas` asks for a password and rejects a wrong one
  - ly, seatd and dnscache are running
  - logging in through ly starts mango (a screenshot is saved)
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
install NixOS. The laptop's disk is **completely erased**.

- **UEFI only.** Turn off **Secure Boot** in the laptop's firmware settings.
  The kernel and GRUB are not signed.
- **Internet access** is needed during the install (about 1.8 GB is
  downloaded from cache.nixos.org, straight onto the laptop's disk).
- **Almost nothing is compiled.** The kernel, firmware, nix, mesa, ly and
  mango all come prebuilt. Only a few small packages that sixos patches
  (busybox, s6-rc, s6-linux-init, abduco, alsa-utils, mdev-like-a-boss) are
  compiled, which takes a few minutes.
- **Logins after the install:**
  - **tty1: ly.** Pick your user, type your password, and mango starts.
  - **tty2 (Ctrl+Alt+F2): rescue console.** Kernel messages appear here,
    with a plain `login:` prompt for root.
  - **`doas`** asks for your password.
  - Password hashes are stored in `/etc/shadow`, readable only by root, and
    never in the Nix store.
- **Not included yet:** sound (no audio server), disk encryption, a screen
  locker, and sshd (see `sshd = true` in step 3 to add it). See
  [Troubleshooting](#troubleshooting) for adding sound.

---

## 1. Boot the live USB

1. Download a **NixOS ISO** from <https://nixos.org/download/>. The
   graphical one makes Wi-Fi easy; the **minimal** one is much smaller, if
   your USB sticks are small. Nothing else is stored on the stick: the
   install builds the system straight onto the laptop's disk. Write the ISO
   to a USB stick from any Linux computer (check `/dev/sdX` with `lsblk`
   first; everything on it is erased):
   `sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
2. Boot the laptop from it and connect to the internet. Ethernet or USB
   tethering from a phone needs no setup. For Wi-Fi on the minimal ISO, see
   [networking in the NixOS manual](https://nixos.org/manual/nixos/stable/#sec-installation-manual-networking).

---

## 2. Collect hardware facts

Open a terminal on the live USB and write down the results:

```sh
# (a) the Wi-Fi interface name (wlan0, wlp2s0, ...)
ip -br link

# (b) the sysfs path of the Wi-Fi card  -> WIFI_SYSFS
readlink -f /sys/class/net/wlp2s0/device
#   example: /sys/devices/pci0000:00/0000:00:14.3

# (c) the Wi-Fi kernel driver -> WIFI_MODULE
basename "$(readlink -f /sys/class/net/wlp2s0/device/driver/module)"
#   example: iwlwifi (Intel), ath11k_pci, mt7921e, rtw89_8852be ...

# (d) the disk -> DISK   (nvme0n1 = NVMe, sda = SATA)
lsblk -d -o NAME,SIZE,MODEL
```

---

## 3. Get this repository and configure it

Still on the live USB:

```sh
cd ~
nix-shell -p git --run 'git clone https://github.com/MaezrFulldive/sixos-laptop.git'
cd sixos-laptop
nano site/hosts/laptop.nix
```

Change the values marked `CHANGE ME`:

```nix
  username = "me";                                   # your user name
  root-disk-modules = [ "nvme" ];                    # "ahci" for a SATA disk
  wifi = {
    module = "iwlwifi";                              # WIFI_MODULE from step 2
    sysfs = "/sys/devices/pci0000:00/0000:00:14.3";  # WIFI_SYSFS from step 2
  };
```

The same file shows how to add programs (`extra-packages`), ly settings and
`sshd = true` (for pushing updates from another computer, step 6; it adds
one more compile, openssh). Everything else is in
[`nix/laptop.nix`](nix/laptop.nix), which the automated test also uses.

---

## 4. Install

**This erases the whole disk.** The script shows the disk and asks you to
type its name before doing anything:

```sh
sudo ./scripts/install-on-live-usb --disk /dev/nvme0n1 --user me --wifi "MyHomeWifi"
```

| option | value |
| --- | --- |
| `--disk` | `DISK` from step 2, e.g. `/dev/nvme0n1` |
| `--user` | the `username` in `site/hosts/laptop.nix` |
| `--wifi` | optional: a Wi-Fi network for the installed system (it asks for the passphrase) |

It asks for the new system's **root password** (rescue console) and **your
password** (ly and doas). Then it:

1. builds the installer (prebuilt, about 300 MB into the live USB's memory)
2. partitions the disk: a 1 GiB EFI partition `ESP` and an ext4 root `sixos`,
   and mounts it at `/mnt`
3. writes `/etc/shadow`, the `/etc` links, ssh host keys and Wi-Fi config,
   and copies this repository to `~/sixos-laptop` on the new disk
4. builds the system **directly into `/mnt/nix/store`** (`nix-build --store
   /mnt`), so the downloads and build files land on the disk, not in the
   live USB's memory
5. copies the kernel and initrd to the ESP and installs GRUB (also at the
   fallback path `EFI/BOOT/BOOTX64.EFI`, so it boots even if the firmware
   forgets the boot entry)

If it stops during the build (step 4, e.g. the network dropped), fix the
cause and run the same command with `--resume` added: it keeps the disk and
everything already downloaded. Without `--resume` it starts over.

When it says it's done, type `reboot` and remove the USB stick.

> `eiwd` is iwd without D-Bus, so there is **no `iwctl`**. To add another
> network later, create `/etc/iwd/networks/<SSID>.psk` containing
> `[Security]` and `Passphrase=...` (see `man iwd.network` for SSIDs with
> special characters).

### Alternative: install from another computer over ssh

If you'd rather build on another Linux computer with Nix,
[`scripts/install-over-ssh`](scripts/install-over-ssh) builds the system
there and copies it to the laptop's disk over the network. Set a root
password on the live USB (`sudo passwd root`), find its address with
`ip -br addr`, then on the other computer:

```sh
./scripts/install-over-ssh LAPTOP_IP --disk /dev/nvme0n1 --user me --wifi "MyHomeWifi"
```

`./scripts/install-over-ssh --help` lists all options.

---

## 5. First boot

1. GRUB shows "sixos". Let it boot.
2. Boot messages go to tty2, so tty1 stays blank until ly appears.
3. **ly on tty1**: your user is already selected and the cursor is in the
   password field, so type your password and press Enter. Mango is the only
   session. (To pick a different user, move up to the login field and use
   Left/Right; ly's login field is a list, not a text box.)
4. **mango** starts with its default config (`/etc/mango/config.conf`):
   - `Alt+Return`: foot terminal
   - `Alt+Space`: rofi launcher
   - `Alt+Q`: close a window
   - `Super+M`: quit mango and go back to ly

   To customize it, run
   `mkdir -p ~/.config/mango && cp /etc/mango/config.conf ~/.config/mango/`
   and edit the copy.
5. **tty2** (Ctrl+Alt+F2) has the boot log and a `login:` prompt for root.

Useful commands (`doas` asks for your password):

```sh
doas s6-rc -a list            # services that are up
doas s6-rc -u change wifi     # start a service (and what it depends on)
doas s6-rc -d change wifi     # stop it
ls /var/log/                  # one log directory per service
tail -f /var/log/wifi/current # e.g. the Wi-Fi log
doas /run/init/bin/poweroff   # shut down   (reboot: /run/init/bin/reboot)
```

To change a password:

```sh
HASH=$(mkpasswd -m sha512)                            # asks for the new password
doas sed -i "s|^me:[^:]*:|me:$HASH:|" /etc/shadow     # use root instead of me for root
```

**Next: [docs/](docs/README.md)** explains how to configure and use the
system: adding programs, sound, services, several machines, and how sixos
differs from NixOS (infusions instead of modules, s6 instead of systemd).

---

## 6. Updating later

Pull the latest tested pins, then rebuild and deploy. Use either option:

**On the laptop itself** (in the copy step 4 made):

```sh
cd ~/sixos-laptop
git pull
nix-build -A hosts.laptop.configuration
doas ./result/bin/deploy
```

**From another computer, pushing to the laptop** (needs `sshd = true` in
`site/hosts/laptop.nix` and `--ssh-key ~/.ssh/id_ed25519.pub` given to the
install command):

```sh
cd ~/sixos-laptop
git pull
nix-build -A hosts.laptop.configuration
nix copy --no-check-sigs --to ssh://root@LAPTOP_IP ./result
ssh root@LAPTOP_IP "$(readlink -f result)/bin/deploy"
```

`deploy` switches the running system to the new one, restarting only the
services that changed. It also makes the new system the default for the
next boot: it copies the kernel and initrd to the ESP and keeps the previous
system as **"sixos (fallback)"** in GRUB.

> ⚠️ If an update changes ly (its package or settings, which most NixOS
> updates do), `deploy` restarts ly, which **ends your mango session**.
> Save your work first, or run `./result/bin/nextboot` instead of `deploy`
> and reboot.

Other commands in `result/bin/`: `activate` (switch the running system only),
`dry-activate` (show what would change), `nextboot` (boot this next time,
don't touch the running system), `kexec` (jump straight into the new kernel).

If you changed `site/hosts/laptop.nix`, commit it on your own branch, so
`git pull` merges the weekly updates into it.

---

## Troubleshooting

**`install-on-live-usb` stopped while building**
Run the same command again with `--resume`; it keeps what was already
downloaded. If the live USB itself runs out of memory before the disk is
prepared (step 1 of the script), use a laptop with more RAM or the
[over-ssh install](#alternative-install-from-another-computer-over-ssh).
"--user ... does not match" means `--user` and `username` in
`site/hosts/laptop.nix` differ.

**`install-over-ssh`: "Permission denied" or "Connection refused"**
Run `sudo passwd root` on the live USB (its root password starts out empty,
and ssh refuses empty passwords). Check `LAPTOP_IP` with `ip -br addr` on the
laptop, and that both machines are on the same network. If the install
stopped halfway, just run the same command again: it starts over.

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

**Wi-Fi doesn't come up**
Read `/var/log/wifi/current`. "does not exist yet, sleeping" means the
`sysfs` value in `site/hosts/laptop.nix` is wrong. Firmware errors in
`dmesg` point at a missing or wrong `module`.

**No sound**
Sound is not set up by default: see [docs/configuring.md](docs/configuring.md#sound).

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
| [`site/hosts/laptop.nix`](site/hosts/laptop.nix) | **your** settings |
| [`nix/laptop.nix`](nix/laptop.nix) | the system configuration: ly, mango, doas, PAM, kernel, services |
| [`docs/`](docs/README.md) | how to configure and use the installed system |
| [`by-name/`](by-name) | services of your own ([docs/services.md](docs/services.md)) |
| [`pins.json`](pins.json) | every upstream source, updated weekly |
| [`patches/sixos/`](patches/sixos) | changes to upstream sixos (below) |
| [`scripts/install-on-live-usb`](scripts/install-on-live-usb) | the install command from step 4 |
| [`scripts/install-over-ssh`](scripts/install-over-ssh) | the same, run from another computer |
| [`installer/sixos-install.sh`](installer/sixos-install.sh) | the part of it that runs on the laptop |
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
