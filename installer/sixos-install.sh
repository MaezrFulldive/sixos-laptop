# sixos-install: erase a disk and install a built sixos system on it.
#
# Run as root from a live system (e.g. the NixOS live USB).  The automated
# test (tests/default.nix) runs this same script inside a VM, so if you change
# it, the test checks your change.

usage() {
  cat <<'EOF'
Usage: sixos-install --disk DEV --system PATH --user NAME [options]

Usually you don't run this yourself: scripts/install-over-ssh (on the build
machine) runs it on the live USB in two phases and copies the system in
between.

Required:
  --disk DEV        the whole disk to ERASE, e.g. /dev/nvme0n1 or /dev/sda
  --system PATH     the built system: the store path `readlink -f result`
                    printed on the build machine
  --user NAME       your user name (the `username` in site/hosts/laptop.nix)

Options:
  --from STORE      copy the system from this Nix store, e.g.
                    ssh://you@192.168.1.10 (default: this machine's store)
  --uid N           your user id (default 1000, as in nix/laptop.nix)
  --ssh-key KEY     a public key (the text, or a .pub file) allowed to log
                    in as root over ssh, so you can push updates later
  --wifi SSID       add a Wi-Fi network; asks for its passphrase
  --copy DIR        copy DIR (e.g. this repo) into the new home directory
  --esp-size SIZE   size of the EFI partition (default 1GiB)
  --yes             don't ask before erasing the disk
  --no-nvram        don't add a firmware boot entry; only install GRUB at the
                    fallback path EFI/BOOT/BOOTX64.EFI (always done anyway)
  --phase PHASE     all (default): everything, copying the system with --from
                    prepare: ask questions, partition, mount at /mnt, write
                             /etc; then stop, so the system can be copied into
                             /mnt from elsewhere (--system is not needed)
                    finish:  after the copy: boot profiles, GRUB, unmount

Passwords are asked for interactively.  For unattended installs, set
SIXOS_ROOT_PASSWORD_HASH and SIXOS_USER_PASSWORD_HASH to SHA-512 crypt
hashes (`openssl passwd -6`).
EOF
}

die() { echo "sixos-install: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

DISK='' SYSTEM='' USERNAME='' FROM='' USER_UID=1000 SSH_KEY='' WIFI_SSID='' COPY_DIR=''
ESP_SIZE=1GiB ASSUME_YES='' NO_NVRAM='' PHASE=all
while [ $# -gt 0 ]; do
  case "$1" in
    --disk) DISK=$2; shift 2 ;;
    --system) SYSTEM=$2; shift 2 ;;
    --user) USERNAME=$2; shift 2 ;;
    --from) FROM=$2; shift 2 ;;
    --uid) USER_UID=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --wifi) WIFI_SSID=$2; shift 2 ;;
    --copy) COPY_DIR=$2; shift 2 ;;
    --esp-size) ESP_SIZE=$2; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-nvram) NO_NVRAM=1; shift ;;
    --phase) PHASE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

case "$PHASE" in
  all|prepare|finish) ;;
  *) die "--phase must be all, prepare or finish" ;;
esac
[ -n "$DISK" ] && [ -n "$USERNAME" ] || { usage >&2; exit 1; }
[ "$PHASE" = prepare ] || [ -n "$SYSTEM" ] || { usage >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must be run as root (sudo -i)"
[ -b "$DISK" ] || die "$DISK is not a block device"
case "$SYSTEM" in
  ''|/nix/store/*) ;;
  *) die "--system must be a /nix/store/... path (run \`readlink -f result\` on the build machine)" ;;
esac
if [ -n "$COPY_DIR" ] && [ ! -d "$COPY_DIR" ]; then die "--copy: $COPY_DIR is not a directory"; fi

# /dev/nvme0n1 -> /dev/nvme0n1p1, /dev/sda -> /dev/sda1
case "$DISK" in
  *[0-9]) PART=${DISK}p ;;
  *) PART=$DISK ;;
esac
ESP=${PART}1
ROOT=${PART}2
MNT=/mnt

if [ "$PHASE" != finish ]; then   # (not indented, to keep the diff readable)

# ---------------------------------------------------------------------------
# Ask everything up front, so the rest runs unattended
# ---------------------------------------------------------------------------

if [ -z "$ASSUME_YES" ]; then
  echo "This ERASES EVERYTHING on $DISK:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL "$DISK" || true
  printf 'Type the disk name (%s) to continue: ' "$DISK"
  read -r answer
  [ "$answer" = "$DISK" ] || die "aborted"
fi

ROOT_HASH=${SIXOS_ROOT_PASSWORD_HASH:-}
USER_HASH=${SIXOS_USER_PASSWORD_HASH:-}
if [ -z "$ROOT_HASH" ]; then
  echo "Choose the ROOT password (for the rescue login on tty2):"
  ROOT_HASH=$(openssl passwd -6) || die "passwords did not match"
fi
if [ -z "$USER_HASH" ]; then
  echo "Choose the password for $USERNAME (for ly and doas):"
  USER_HASH=$(openssl passwd -6) || die "passwords did not match"
fi

WIFI_PASS=
if [ -n "$WIFI_SSID" ]; then
  printf 'Wi-Fi passphrase for %s: ' "$WIFI_SSID"
  stty -echo 2>/dev/null || true
  read -r WIFI_PASS
  stty echo 2>/dev/null || true
  echo
fi

set -x

# ---------------------------------------------------------------------------
step "Partitioning $DISK"
# ---------------------------------------------------------------------------

umount -R "$MNT" 2>/dev/null || true
wipefs -a "$DISK"
parted -s "$DISK" -- \
  mklabel gpt \
  mkpart ESP fat32 1MiB "$ESP_SIZE" \
  set 1 esp on \
  mkpart sixos ext4 "$ESP_SIZE" 100%
# wait for the partition device nodes to appear
for _ in $(seq 50); do [ -b "$ROOT" ] && break; sleep 0.1; done
[ -b "$ROOT" ] || die "$ROOT did not appear after partitioning"

mkfs.fat -F 32 -n ESP "$ESP"
mkfs.ext4 -F -q -L sixos "$ROOT"

mkdir -p "$MNT"
mount "$ROOT" "$MNT"
mkdir -p "$MNT/boot"
mount "$ESP" "$MNT/boot"

# ---------------------------------------------------------------------------
step "Directories, passwords and /etc"
# ---------------------------------------------------------------------------

mkdir -p "$MNT"/dev "$MNT"/proc "$MNT"/sys "$MNT"/run "$MNT"/etc/ssh "$MNT"/var
install -d -m 0700 "$MNT/root"
install -d -m 1777 "$MNT/tmp"
install -d -m 0755 "$MNT/home"
install -d -m 0700 -o "$USER_UID" -g "$USER_UID" "$MNT/home/$USERNAME"

# Password hashes live only here, never in the Nix store.  SHA-512 ($6$)
# because busybox `login` doesn't understand yescrypt.
set +x   # don't print the hashes
(
  umask 077
  printf 'root:%s:::::::\n%s:%s:::::::\n' "$ROOT_HASH" "$USERNAME" "$USER_HASH" > "$MNT/etc/shadow"
)
set -x
chmod 600 "$MNT/etc/shadow"

# /etc entries that follow the running configuration (and so every update)
for d in pam.d mango fonts; do
  ln -sfn "/run/current-system/etc/$d" "$MNT/etc/$d"
done

# Consoles where root may log in.  This file must exist: busybox `login`
# (1.36) otherwise rejects root's correct password, because the failed attempt
# to open it leaves an error behind that breaks its /etc/shadow lookup.
{
  for i in $(seq 1 12); do echo "tty$i"; done
  for i in 0 1 2 3; do echo "ttyS$i"; done
  echo console
} > "$MNT/etc/securetty"

echo 'nameserver 127.0.0.1' > "$MNT/etc/resolv.conf"   # the local dnscache

# sshd host keys (sshd runs by default; password logins are disabled)
ssh-keygen -A -f "$MNT"
if [ -n "$SSH_KEY" ]; then
  install -d -m 0700 "$MNT/root/.ssh"
  if [ -f "$SSH_KEY" ]; then cat "$SSH_KEY"; else echo "$SSH_KEY"; fi \
    >> "$MNT/root/.ssh/authorized_keys"
  chmod 600 "$MNT/root/.ssh/authorized_keys"
fi

# Wi-Fi (eiwd: iwd without D-Bus, configured only through files)
install -d -m 0700 "$MNT/etc/iwd" "$MNT/etc/iwd/networks"
cat > "$MNT/etc/iwd/main.conf" <<'EOF'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=none
EOF
if [ -n "$WIFI_SSID" ]; then
  set +x
  (
    umask 077
    printf '[Security]\nPassphrase=%s\n' "$WIFI_PASS" > "$MNT/etc/iwd/networks/$WIFI_SSID.psk"
  )
  set -x
fi

if [ -n "$COPY_DIR" ]; then
  cp -a "$COPY_DIR" "$MNT/home/$USERNAME/"
  rm -f "$MNT/home/$USERNAME/$(basename "$COPY_DIR")"/result*
  chown -R "$USER_UID:$USER_UID" "$MNT/home/$USERNAME"
fi

fi  # end of the prepare part

if [ "$PHASE" = prepare ]; then
  set +x
  echo
  echo "$DISK is partitioned and mounted at $MNT.  Copy the system into $MNT,"
  echo "then run this again with --phase finish."
  exit 0
fi

if [ "$PHASE" = finish ]; then
  if ! mountpoint -q "$MNT" || ! mountpoint -q "$MNT/boot"; then
    die "$MNT is not mounted: run --phase prepare first"
  fi
  set -x
else
  # -------------------------------------------------------------------------
  step "Copying the system and everything it needs into $MNT/nix/store"
  # -------------------------------------------------------------------------
  if [ -n "$FROM" ]; then
    nix --extra-experimental-features nix-command copy --no-check-sigs \
      --from "$FROM" --to "$MNT" "$SYSTEM"
  else
    nix --extra-experimental-features nix-command copy --no-check-sigs \
      --to "$MNT" "$SYSTEM"
  fi
fi
[ -e "$MNT$SYSTEM/bin/activate" ] || die "$SYSTEM is not in $MNT/nix/store, or is not a sixos system (no bin/activate)"

# ---------------------------------------------------------------------------
step "Boot profiles"
# ---------------------------------------------------------------------------

# The initrd boots whatever /nix/var/nix/profiles/nextboot points to.
P=$MNT/nix/var/nix/profiles
mkdir -p "$P/per-user"   # the first activation needs this
ln -sfn "$SYSTEM" "$P/nextboot-1-link"
ln -sfn nextboot-1-link "$P/nextboot"
ln -sfn "$SYSTEM" "$P/fallbackboot-1-link"
ln -sfn fallbackboot-1-link "$P/fallbackboot"
mkdir -p "$MNT/nix/var/nix/gcroots"
ln -sfn /nix/var/nix/profiles "$MNT/nix/var/nix/gcroots/profiles"

# ---------------------------------------------------------------------------
step "Kernel, initrd and GRUB"
# ---------------------------------------------------------------------------

# boot/kernel and boot/initrd are symlinks to absolute /nix/store/... paths.
# Those must be followed inside $MNT: when the system was built straight into
# $MNT/nix/store (install-on-live-usb), the live USB's own /nix/store doesn't
# have them, so `cp -L` would fail.
in_mnt() {
  local p=$1 t n=0
  while [ -L "$MNT$p" ]; do
    n=$((n + 1)); [ "$n" -le 40 ] || die "too many symlinks at $MNT$1"
    t=$(readlink "$MNT$p")
    case "$t" in
      /*) p=$t ;;
      *) p=$(dirname "$p")/$t ;;
    esac
  done
  [ -e "$MNT$p" ] || die "$MNT$1 points to $p, which is not in $MNT"
  echo "$MNT$p"
}
KERNEL=$(in_mnt "$SYSTEM/boot/kernel")
INITRD=$(in_mnt "$SYSTEM/boot/initrd")

# Same layout that sixos's `nextboot` keeps up to date later on
for d in normal fallback; do
  mkdir -p "$MNT/boot/sixos/$d"
  cp "$KERNEL" "$MNT/boot/sixos/$d/kernel"
  cp "$INITRD" "$MNT/boot/sixos/$d/initrd"
done

# Always install at the fallback path EFI/BOOT/BOOTX64.EFI, which every UEFI
# firmware tries; also add a "sixos" firmware boot entry when possible.
grub-install --target=x86_64-efi --efi-directory="$MNT/boot" \
  --boot-directory="$MNT/boot" --removable --no-nvram
if [ -z "$NO_NVRAM" ] && [ -d /sys/firmware/efi/efivars ]; then
  grub-install --target=x86_64-efi --efi-directory="$MNT/boot" \
    --boot-directory="$MNT/boot" --bootloader-id=sixos \
    || echo "warning: could not add a firmware boot entry; the fallback path still works"
fi

# The kernel command line, with init= and configuration= replaced by the
# boot *profiles* instead of one store path: GRUB then always boots whatever
# `nextboot` (or `fallbackboot`) points to, so updates never need GRUB
# changes.  (configuration= must be present: after switch_root, s6's rc.init
# reads it to find the system to activate.)
PARAMS=$(tr ' ' '\n' < "$MNT$SYSTEM/boot/kernel-params" \
  | grep -v -e '^init=' -e '^configuration=' -e '^$' | tr '\n' ' ')
PARAMS=${PARAMS% }

cat > "$MNT/boot/grub/grub.cfg" <<EOF
# Written once by sixos-install.  sixos never regenerates this file; updates
# only replace the files under /sixos/normal and /sixos/fallback.
set timeout=3
search --no-floppy --label --set=root ESP

menuentry "sixos" {
    linux  /sixos/normal/kernel $PARAMS configuration=/nix/var/nix/profiles/nextboot
    initrd /sixos/normal/initrd
}

menuentry "sixos (fallback: previously booted system)" {
    linux  /sixos/fallback/kernel $PARAMS configuration=/nix/var/nix/profiles/fallbackboot
    initrd /sixos/fallback/initrd
}
EOF

sync
umount "$MNT/boot" "$MNT"
set +x

echo
echo "sixos is installed on $DISK.  Remove the USB stick and reboot."
