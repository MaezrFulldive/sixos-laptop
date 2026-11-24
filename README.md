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
  It builds the laptop configuration, then runs the real
  [installer](installer/sixos-install.sh) inside a VM onto an empty disk.
  It boots that disk with UEFI and an NVMe drive, the way a laptop does, and
  checks the following ([details](tests/default.nix)):
  - the system boots to a login prompt
  - passwords work for root and the user
  - `doas` asks for a password and rejects a wrong one
  - ly, seatd, dnscache and sshd are running
  - logging in through ly starts mango (a screenshot is saved)
  - `poweroff` powers off instead of rebooting

  It also checks every link in this README.
- The changes this setup needs in sixos are kept as small patches in
  [`patches/sixos/`](patches/sixos) and applied to the pinned upstream sixos at
  build time. If upstream changes so much that one stops applying, the test
  fails and nothing is updated.

---

## 0. Before you start

Two machines are involved:

| name in this guide | what it is |
| --- | --- |
| **build machine** | your current Linux computer (Arch here). It builds the system. |
| **target laptop** | the laptop that gets sixos. Its disk is **completely erased**. |

- The target laptop boots from a **NixOS live USB** for the install. It
  already has `nix`, `ssh` and Wi-Fi tools. You only use it for the
  install; you don't install NixOS.
- **UEFI only.** Turn off **Secure Boot** in the laptop's firmware settings.
  The kernel and GRUB are not signed.
- **Logins after the install:**
  - **tty1: ly.** Pick your user, type your password, and mango starts.
  - **tty2 (Ctrl+Alt+F2): rescue console.** Kernel messages appear here,
    with a plain `login:` prompt for root.
  - **`doas`** asks for your password.
  - Password hashes are stored in `/etc/shadow`, readable only by root, and
    never in the Nix store.
- **Not included yet:** sound (no audio server), disk encryption and a
  screen locker. See [Troubleshooting](#troubleshooting) for adding sound.

---

## 1. Prepare the build machine

Install Nix (on Arch: `sudo pacman -S nix`), then:

```sh
sudo systemctl enable --now nix-daemon.service
sudo systemctl enable --now sshd.service      # the laptop pulls the build over ssh
sudo usermod -aG nix-users "$USER"            # then log out and back in
```

Get this repository and check that Nix works:

```sh
git clone https://github.com/MaezrFulldive/sixos-laptop.git ~/sixos-laptop
cd ~/sixos-laptop
nix-build --version
```

Write down the build machine's IP address (`ip -br addr`); this guide calls
it `BUILD_IP`. Your user name on it is `BUILD_USER`.

---

## 2. Collect hardware facts from the target laptop

1. Download the **NixOS graphical ISO** from <https://nixos.org/download/>.
   The graphical one makes Wi-Fi easy. Write it to a USB stick (check
   `/dev/sdX` with `lsblk` first; everything on it is erased):
   `sudo dd if=nixos-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
2. Boot the target laptop from it and connect to the internet.
3. Open a terminal, run these commands and write down the results:

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

Leave the live USB running; you'll need it again in step 4.

---

## 3. Configure and build (on the build machine)

Open [`site/hosts/laptop.nix`](site/hosts/laptop.nix) and change the values
marked `CHANGE ME`:

```nix
  username = "me";                                   # your user name
  root-disk-modules = [ "nvme" ];                    # "ahci" for a SATA disk
  wifi = {
    module = "iwlwifi";                              # WIFI_MODULE from step 2
    sysfs = "/sys/devices/pci0000:00/0000:00:14.3";  # WIFI_SYSFS from step 2
  };
```

The same file shows how to add programs (`extra-packages`) and ly
settings. Everything else is in [`nix/laptop.nix`](nix/laptop.nix), which the
automated test also uses.

Build:

```sh
cd ~/sixos-laptop
nix-build -A hosts.laptop.configuration
readlink -f result      # /nix/store/...-six-system-laptop-...  -> write this down: SYSTEM
```

Almost everything downloads prebuilt from cache.nixos.org (about 2 GB). Only
a few small packages that sixos patches are compiled. If the build fails,
see [Troubleshooting](#troubleshooting).

---

## 4. Install (on the target laptop, in the NixOS live USB)

Open a terminal on the live USB and get the installer from the build machine:

```sh
scp -r BUILD_USER@BUILD_IP:sixos-laptop ~/sixos-laptop
cd ~/sixos-laptop
nix-build -A installer       # small: GRUB, parted, mkfs ...
```

Then run it. **It erases the whole disk.** It shows the disk and asks you to
type its name before doing anything:

```sh
sudo ./result/bin/sixos-install \
  --disk /dev/nvme0n1 \
  --system /nix/store/...-six-system-laptop-... \
  --user me \
  --from ssh://BUILD_USER@BUILD_IP \
  --wifi "MyHomeWifi" \
  --ssh-key "$(ssh BUILD_USER@BUILD_IP cat .ssh/id_ed25519.pub)" \
  --copy ~/sixos-laptop
```

| option | value |
| --- | --- |
| `--disk` | `DISK` from step 2, e.g. `/dev/nvme0n1` |
| `--system` | `SYSTEM` from step 3 |
| `--user` | the `username` in `site/hosts/laptop.nix` |
| `--from` | where the built system is; it is copied over ssh |
| `--wifi` | optional: a Wi-Fi network to join (it asks for the passphrase) |
| `--ssh-key` | optional: lets the build machine log in as root to push updates (step 6) |
| `--copy` | optional: copies this repo into your new home directory |

It asks for the **root password** (rescue console) and **your password** (ly
and doas). Then it does everything that used to be manual:

1. partitions the disk: a 1 GiB EFI partition `ESP` and an ext4 root `sixos`
2. copies the system into the new `/nix/store` and sets up the boot profiles
3. writes `/etc/shadow`, the `/etc` links, ssh host keys and Wi-Fi config
4. copies the kernel and initrd to the ESP
5. installs GRUB (also at the fallback path `EFI/BOOT/BOOTX64.EFI`, so it
   boots even if the firmware forgets the boot entry) and writes `grub.cfg`

`sixos-install --help` lists all options. When it says it's done:

```sh
reboot      # and remove the USB stick
```

> `eiwd` is iwd without D-Bus, so there is **no `iwctl`**. To add another
> network later, create `/etc/iwd/networks/<SSID>.psk` containing
> `[Security]` and `Passphrase=...` (see `man iwd.network` for SSIDs with
> special characters).

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

---

## 6. Updating later

Pull the latest tested pins, then rebuild and deploy. Use either option:

**On the build machine, pushing to the laptop** (needs `--ssh-key` from step 4):

```sh
cd ~/sixos-laptop
git pull
nix-build -A hosts.laptop.configuration
nix copy --no-check-sigs --to ssh://root@LAPTOP_IP ./result
ssh root@LAPTOP_IP "$(readlink -f result)/bin/deploy"
```

**On the laptop itself** (using the copy from `--copy`):

```sh
cd ~/sixos-laptop
git pull
nix-build -A hosts.laptop.configuration
doas ./result/bin/deploy
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

**tty1 stays blank (no ly)**
Switch to tty2 (Ctrl+Alt+F2), log in as root, and check
`s6-rc -a list | grep -e ly -e seatd -e run-user` and
`tail /var/log/ly/current`. Start ly by hand with `s6-rc -u change ly`.

**ly says the login failed although the password is right**
`ls -l /etc/pam.d/` must list `ly`, `doas` and `other`. `/etc/shadow` must
contain a `$6$...` hash for your user and be mode 600.

**mango starts and exits immediately (you're back in ly)**
Read `~/ly-session.log` and `/var/log/ly.log`. Then check that
`/run/user/1000` exists, that `/run/seatd.sock` exists, and that `id` lists
`_video`. To see mango's own errors, log in on tty2 as your user and run
`XDG_RUNTIME_DIR=/run/user/1000 mango`.

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
Add `pipewire` and `wireplumber` to `extra-packages` and start them from
mango's config (`exec-once=`).

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
| [`pins.json`](pins.json) | every upstream source, updated weekly |
| [`patches/sixos/`](patches/sixos) | changes to upstream sixos (below) |
| [`installer/sixos-install.sh`](installer/sixos-install.sh) | the installer from step 4 |
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
4. `0004`: the `ly-dm` service (the ly display manager).
5. `0005`: downloads `mdev-like-a-boss` from a mirror. Its original GitHub
   repository was deleted, which breaks every sixos build; the hash pins the
   exact same contents.

## Further reading

- sixos: <https://codeberg.org/amjoseph/sixos>, including `doc/README.md`
- Talk: <https://media.ccc.de/v/38c3-sixos-a-nix-os-without-systemd>
- mango: <https://github.com/DreamMaoMao/mangowc>
- ly: <https://codeberg.org/fairyglade/ly>
