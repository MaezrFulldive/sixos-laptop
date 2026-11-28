# The sixos host configuration shared by every machine in site/hosts/:
# networking (NetworkManager), the tools to repair a system from its own
# console, and optionally the desktop (ly + mango, nix/desktop.nix).
#
# site/hosts/<name>.nix calls this with the settings that differ from machine
# to machine (user name, disk driver, desktop or not).  The automated test
# calls it with settings for a QEMU virtual machine
# (tests/site/hosts/testvm.nix), so the test boots exactly this configuration.

# arguments sixos passes to every file in site/
{ lib, infuse, sources, ... }:

# settings, from site/hosts/<name>.nix
{ username
, uid ? 1000

  # kernel modules the initrd loads so the root disk appears:
  # "nvme" for NVMe disks, "ahci" for SATA
, root-disk-modules ? [ "nvme" ]

  # ly + mango and the desktop programs (nix/desktop.nix).  Without it the
  # machine boots to a text login on tty1.
, desktop ? true

  # qutebrowser, with mpv + yt-dlp for videos, GStreamer, spell checking and
  # its PDF viewer (needs desktop)
, qutebrowser ? false

  # the console that shows kernel messages and the rescue `login:` prompt
  # (tty2 with the desktop, because tty1 is ly's)
, console ? { device = if desktop then "tty2" else "tty1"; }

  # extra NetworkManager.conf settings, e.g. { main.dns = "none"; }
, networkmanager-settings ? { }

  # extra programs from nixpkgs-desktop, e.g. `pkgs: [ pkgs.firefox ]`
, extra-packages ? (pkgs: [ ])

  # extra settings for /etc/ly/config.ini
, ly-settings ? { }

  # extra kernel command line parameters
, kernel-params ? [ ]

  # run sshd, so another machine can log in as root (with the key given to
  # the installer's --ssh-key) and push updates.  Off by default: sixos's
  # sshd service always compiles its own openssh.
, sshd ? false

  # Programs started in the background when you log in through ly, and
  # stopped when mango exits: this setup's replacement for systemd user
  # services.  They run as you, inside the session's D-Bus bus, e.g.
  #   [ "mako" "waybar" ]
  # (the programs themselves go in extra-packages; sound is always started).
, session-commands ? [ ]

  # More configuration for this one machine, as infusions on the host (see
  # docs/sixos-for-nixos-users.md), e.g.
  #   host: { targets.earlyoom.__assign = host.services.earlyoom { }; }
  # `host` is the finished host (host-final); its .services, .targets and
  # .pkgs are what sixos passes to services.
, extra-config ? (host: [ ])
}:

host-final: host-prev:

let
  pkgs = host-final.pkgs;               # base system (sixos's pinned nixpkgs)
  desktop-pkgs = sources.desktop-pkgs;  # kernel, firmware and desktop

  # PAM is used by ly (and by doas if it was built with PAM).  Each service
  # uses the pam_unix.so from the same nixpkgs as the program itself.
  # pam_unix reads the password hashes from /etc/shadow.
  pam-unix-service = linux-pam: ''
    auth     required ${linux-pam}/lib/security/pam_unix.so
    account  required ${linux-pam}/lib/security/pam_unix.so
    password required ${linux-pam}/lib/security/pam_unix.so sha512
    session  required ${linux-pam}/lib/security/pam_unix.so
  '';
  # TLS certificates (Mozilla's list, as on NixOS).  Without them git, curl
  # and nix can't use https.  They are in /run/current-system/etc/ssl, and
  # /etc/ssl links there (the etc-ssl target below), so updates replace them.
  ca-file = "/run/current-system/etc/ssl/certs/ca-certificates.crt";

  desktop-cfg = import ./desktop.nix {
    inherit lib desktop-pkgs ca-file session-commands qutebrowser;
  };

  # D-Bus policies for the system bus (who may own and call which names)
  networkmanager = desktop-pkgs.networkmanager;
  wpa_supplicant = desktop-pkgs.wpa_supplicant;

  # Enough to repair or reinstall the system from its own console, with no
  # second computer: network (nmtui), editors, git, disks, a text browser.
  # These come before busybox in $PATH, so they win over its smaller
  # versions of the same commands.
  tools-before-busybox = with desktop-pkgs; [ vim less iproute2 wget procps ];
  rescue-tools = with desktop-pkgs; [
    networkmanager wpa_supplicant iw      # nmtui, nmcli, wpa_cli, iw
    git curl openssh rsync                # ssh/scp (the client only)
    nano htop tmux file tree jq ripgrep ncdu lsof
    w3m                                   # a text web browser (captive portals, docs)
    util-linux e2fsprogs dosfstools gptfdisk parted efibootmgr   # disks and boot
    pciutils usbutils                     # lspci, lsusb
    unzip zip xz zstd
  ];

  # `sixos-rebuild switch` and friends: build this machine's configuration
  # from ~/sixos-laptop and switch to it (docs/configuring.md).
  sixos-rebuild = desktop-pkgs.writeShellScriptBin "sixos-rebuild" ''
    set -eu
    usage() {
      cat <<'EOF'
    Usage: sixos-rebuild ACTION [--host NAME]

    Builds this machine's configuration from $SIXOS_CONFIG (default
    ~/sixos-laptop), then:

      switch        switch to it now, and boot it from now on    (result/bin/deploy)
      boot          boot it from the next boot on                (result/bin/nextboot)
      test          switch to it now, until the next reboot      (result/bin/activate)
      build         nothing: just build it (./result)
      dry-activate  show which services would start, stop or restart

    Run it as your user; it asks doas for the steps that need root.  If ly
    changed, `switch` restarts it, which ends your mango session: use `boot`
    and reboot instead.
    EOF
    }
    action=''${1:-}
    [ $# -gt 0 ] && shift
    host=$(cat /proc/sys/kernel/hostname)
    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host=$2; shift 2 ;;
        *) usage >&2; exit 1 ;;
      esac
    done
    case "$action" in
      switch) step=deploy ;;
      boot) step=nextboot ;;
      test) step=activate ;;
      dry-activate) step=dry-activate ;;
      build) step= ;;
      -h|--help|help) usage; exit 0 ;;
      *) usage >&2; exit 1 ;;
    esac
    if [ "$(id -u)" = 0 ]; then
      echo "sixos-rebuild: run it as your user, not with doas (it uses doas itself)" >&2
      exit 1
    fi
    config=''${SIXOS_CONFIG:-$HOME/sixos-laptop}
    cd "$config" || { echo "sixos-rebuild: no configuration in $config (set SIXOS_CONFIG)" >&2; exit 1; }
    [ -f "site/hosts/$host.nix" ] || { echo "sixos-rebuild: there is no $config/site/hosts/$host.nix (use --host)" >&2; exit 1; }
    echo "building hosts.$host.configuration in $config"
    nix-build -A "hosts.$host.configuration" -o result
    if [ -n "$step" ]; then
      exec doas ./result/bin/$step
    fi
  '';

  pam-d = pkgs.linkFarm "pam.d" {
    ly = pkgs.writeText "pam-ly" (pam-unix-service desktop-pkgs.linux-pam);
    doas = pkgs.writeText "pam-doas" (pam-unix-service pkgs.linux-pam);
    # anything without its own file is denied
    other = pkgs.writeText "pam-other" ''
      auth     required ${pkgs.linux-pam}/lib/security/pam_deny.so
      account  required ${pkgs.linux-pam}/lib/security/pam_deny.so
      password required ${pkgs.linux-pam}/lib/security/pam_deny.so
      session  required ${pkgs.linux-pam}/lib/security/pam_deny.so
    '';
  };
in
infuse host-prev ([{

  ##########################################################################
  # Platform and package set
  ##########################################################################

  canonical.__assign = "x86_64-unknown-linux-gnu";

  pkgs.__assign = import sources.nixpkgs-path {
    localSystem = "x86_64-linux";
    overlays = import (sources.sixos-path + "/pkgs/overlays.nix") { inherit lib infuse; } ++ [
      # sixos patches busybox (for its modprobe), and nix embeds a static
      # busybox as its build sandbox's /bin/sh, so every nix would be
      # recompiled.  The sandbox shell doesn't need the patch: with the
      # unpatched one, nix comes prebuilt from cache.nixos.org.
      (final: prev: {
        busybox-sandbox-shell = (import sources.nixpkgs-path {
          localSystem = "x86_64-linux";
          config = { };
          overlays = [ ];
        }).busybox-sandbox-shell;
      })
    ];
  };

  # Everything in here ends up in $PATH (/run/current-system/sw/bin).  Its
  # share/wayland-sessions/ is where ly finds the "mango" session, and its
  # lib/dri is where mesa's GPU drivers are found (/run/opengl-driver).
  sw.__assign = pkgs.buildEnv {
    name = "laptop-sw";
    ignoreCollisions = true; # e.g. busybox and bash both provide bin/sh; first one wins
    paths =
      tools-before-busybox
      # required by sixos itself
      ++ (with pkgs; [ busybox s6 s6-rc doas nix bashInteractive ])
      ++ [ sixos-rebuild ]
      ++ rescue-tools
      ++ lib.optionals desktop desktop-cfg.packages
      ++ extra-packages desktop-pkgs;
  };

  # Files under /run/current-system/etc/.  The installer links /etc/pam.d,
  # /etc/mango, /etc/fonts and /etc/ssl to them once; /etc/profile is linked
  # automatically on first boot.
  extra-configuration-links.__assign = {
    "etc/pam.d" = pam-d;
    "etc/profile" = pkgs.writeText "profile" ''
      # /run/six/bin first: that's where the setuid-root doas lives
      export PATH=/run/six/bin:/run/current-system/sw/bin
      # .desktop files (rofi -show drun), icons, D-Bus services, man pages ...
      export XDG_DATA_DIRS=/run/current-system/sw/share
      # https certificates, for git, curl, nix ...
      export SSL_CERT_FILE=${ca-file}
      export NIX_SSL_CERT_FILE=${ca-file}
      export EDITOR=vim PAGER=less
    '';
    # for Nix run as root (deploy, nextboot): sixos's build group is
    # _nixbld, not Nix's default `nixbld`
    "etc/nix/nix.conf" = pkgs.writeText "nix.conf" ''
      build-users-group = _nixbld
      ssl-cert-file = ${ca-file}
    '';
    "etc/ssl/certs/ca-certificates.crt" = "${desktop-pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    "etc/ssl/certs/ca-bundle.crt" = "${desktop-pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    # where nixpkgs' git/curl look when SSL_CERT_FILE isn't set (e.g. with doas)
    "etc/ssl/cert.pem" = "${desktop-pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    "etc/fonts/fonts.conf" = desktop-pkgs.makeFontsConf {
      fontDirectories = with desktop-pkgs; [ dejavu_fonts noto-fonts noto-fonts-color-emoji ];
    };
  } // lib.optionalAttrs desktop {
    "etc/mango/config.conf" = desktop-cfg.mango-config;
    "etc/mango/sixos.conf" = desktop-cfg.sixos-conf;
  };

  ##########################################################################
  # Boot
  ##########################################################################

  # Prebuilt kernel + firmware from nixpkgs-desktop: nothing to compile.
  # The firmware is the zstd-compressed copy NixOS itself uses (0.9 GB instead
  # of 2 GB; the kernel decompresses it).  It is on cache.nixos.org too,
  # because the NixOS ISOs contain it.
  boot.kernel.package.__assign = desktop-pkgs.linuxPackages.kernel;
  boot.kernel.firmware.__assign = [
    (desktop-pkgs.compressFirmwareZstd desktop-pkgs.linux-firmware)
  ];
  boot.kernel.params.__append = [
    "firmware_class.path=/run/booted-system/firmware/lib/firmware"
  ] ++ kernel-params;

  # Boot messages and the rescue `login:` prompt go to `console`, leaving tty1
  # free for ly.  With console-autologin = false the console asks for a user
  # name and password instead of giving out a root shell.
  boot.console-autologin.__assign = false;
  boot.kernel.console.__assign = console;
  # where the initrd shows its console (and the disk password prompt, if encrypted)
  boot.initrd.ttys.__assign = { tty1 = null; };

  # Root filesystem = the ext4 partition labelled `sixos`
  # (the initrd's default would be LABEL=boot)
  boot.rootfs.label.__assign = "sixos";
  boot.initrd.mount-root.__assign = [ ''
    mount -o ro LABEL=sixos /root || exit 1
  '' ];
  boot.initrd.insmod.__assign = root-disk-modules;

  # No LVM in the initrd: the root is a plain ext4 partition.  (sixos turns
  # it on by default, but with the base nixpkgs the static lvm2 is built as a
  # library only, without the `dmsetup.static` the initrd wants.)
  tags.has-initrd-lvm.__assign = false;

  # Let `deploy`/`nextboot` copy the kernel and initrd to the EFI partition,
  # which GRUB reads them from.
  tags.is-bootloader-grub.__assign = true;
  boot.loader.filesystem.spec.__assign = "LABEL=ESP";

  ##########################################################################
  # Users and passwords
  ##########################################################################

  # "x" means: the real password hash is in /etc/shadow (written by the installer)
  users.root.hashed-password.__assign = "x";
  users.${username}.__assign = {
    inherit uid;
    hashed-password = "x";
    home-directory = "/home/${username}";
    shell = "${pkgs.bashInteractive}/bin/bash";
    groups = [ "wheel" "_video" "_input" "_audio" ];
  };

  # doas: root needs no password; members of wheel must type theirs.
  # (sixos's default is "permit nopass :wheel".)
  doas-conf.__assign = [
    "permit nopass root"
    "permit :wheel"
  ];

  ##########################################################################
  # Services (each target is started at boot)
  ##########################################################################

  # Network: NetworkManager (`nmtui`), for Wi-Fi and wired networks, DHCP
  # and /etc/resolv.conf.  It and wpa_supplicant talk over the D-Bus system
  # bus.  (by-name/ne/networkmanager, by-name/wp/wpa-supplicant,
  # by-name/db/dbus-system)
  targets.dbus.__assign = host-final.services.dbus-system {
    packages = [ networkmanager wpa_supplicant ];
  };
  targets.wpa-supplicant.__assign = host-final.services.wpa-supplicant {
    package = wpa_supplicant;
    after = [ host-final.targets.dbus ];
  };
  targets.networkmanager.__assign = host-final.services.networkmanager {
    package = networkmanager;
    settings = networkmanager-settings;
    after = [ host-final.targets.dbus host-final.targets.wpa-supplicant ];
  };

  # compressed swap in RAM
  targets.zram.__assign = host-final.services.zram { size-percent = 50; };

  # pam_unix checks the password of a *non-root* caller (e.g. a user running
  # doas, or a screen locker) with the setuid helper `unix_chkpwd`, which
  # nixpkgs' PAM expects at the NixOS path /run/wrappers/bin.  Without it,
  # doas rejects every password.
  targets.pam-helpers.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "pam-helpers-up" ''
      #!${pkgs.runtimeShell} -e
      ${pkgs.busybox}/bin/mkdir -p /run/wrappers/bin
      ${pkgs.busybox}/bin/cp ${pkgs.linux-pam}/bin/unix_chkpwd /run/wrappers/bin/.unix_chkpwd.tmp
      ${pkgs.busybox}/bin/chown root:root /run/wrappers/bin/.unix_chkpwd.tmp
      ${pkgs.busybox}/bin/chmod 4511 /run/wrappers/bin/.unix_chkpwd.tmp
      ${pkgs.busybox}/bin/mv -f /run/wrappers/bin/.unix_chkpwd.tmp /run/wrappers/bin/unix_chkpwd
    '';
  };

  # /etc/ssl -> /run/current-system/etc/ssl, for programs that look for
  # certificates there rather than in $SSL_CERT_FILE (e.g. anything run with
  # doas, which clears the environment), and /etc/nix (nix.conf, above).
  # Systems installed before these existed get the links when this starts
  # (at boot, or when `deploy` switches to a system that has it).
  targets.etc-ssl.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "etc-ssl-up" ''
      #!${pkgs.runtimeShell}
      for d in ssl nix; do
        if [ ! -e /etc/$d ] && [ ! -L /etc/$d ]; then
          ${pkgs.busybox}/bin/ln -s /run/current-system/etc/$d /etc/$d || true
        fi
      done
      true
    '';
    passthru.after = [ host-final.targets.mounts."" ];
  };

  # `nextboot` mounts the EFI partition (FAT) with busybox mount, which only
  # tries the filesystems the kernel has loaded; nothing loads FAT before
  # that, so the mount fails with "Invalid argument".  Load it at boot.
  targets.esp-modules.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "esp-modules-up" ''
      #!${pkgs.runtimeShell}
      for m in vfat nls_cp437 nls_iso8859_1; do
        /run/current-system/boot/modprobe-wrapped $m || true
      done
      true
    '';
  };

  # The nix-daemon does the downloading for `nix-build` run as a user; it is
  # started before /etc/ssl may exist, so tell it where the certificates are.
  targets.nix-daemon.__assign = host-final.services.nix-daemon {
    options.ssl-cert-file = ca-file;
  };

}

# sixos runs a local DNS cache by default; here NetworkManager writes the
# DNS servers each network hands out to /etc/resolv.conf instead.
{ targets = t: builtins.removeAttrs t [ "dnscache" ]; }

# sixos runs sshd by default.  With `sshd = true`, allow key logins only,
# never passwords; otherwise leave it out.
(if sshd then {
  targets.sshd.__assign = host-final.services.sshd {
    extraConfig = ''
      PasswordAuthentication no
    '';
  };
} else {
  targets = t: builtins.removeAttrs t [ "sshd" ];
})

] ++ lib.optional desktop {

  # Seat management, so mango can use the GPU and input devices without
  # running as root.  Any member of _video may take the seat.
  targets.seatd.__assign = host-final.services.seatd {
    user = "root";
    group = "_video";
  };

  # ly sets XDG_RUNTIME_DIR=/run/user/<uid> but doesn't create it (on other
  # distros logind does that), so create it at boot.
  targets.run-user.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "run-user-up" ''
      #!${pkgs.runtimeShell} -e
      ${pkgs.busybox}/bin/mkdir -p /run/user
      ${pkgs.busybox}/bin/mkdir -p -m 0700 /run/user/${toString uid}
      ${pkgs.busybox}/bin/chown ${toString uid}:${toString uid} /run/user/${toString uid}
    '';
    passthru.after = [ host-final.targets.mounts."" ];
  };

  # Login screen on tty1 (patches/sixos/0004-ly-service.patch)
  targets.ly.__assign = host-final.services.ly-dm {
    package = desktop-pkgs.ly;
    tty = 1;
    settings = {
      # mango is the only session, so it is always the one ly starts.
      # (ly's built-in "shell" and "xinitrc" sessions would otherwise be
      # listed first and preselected; tty2 has a console login if you need
      # a plain shell.)
      shell = false;
      xinitrc = null;     # no X11
      xsessions = null;
    } // ly-settings;
    default-user = username;
    after = [
      host-final.targets.seatd
      host-final.targets.run-user
      host-final.targets.pam-helpers
    ];
  };

  # nixpkgs' gnome-keyring starts (over D-Bus) the NixOS path
  # /run/wrappers/bin/gnome-keyring-daemon; NixOS puts a wrapper there that
  # may lock memory.  A plain link is enough: without that capability the
  # keyring just can't keep secrets out of swap (zram here, so in RAM anyway).
  targets.keyring-wrapper.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "keyring-wrapper-up" ''
      #!${pkgs.runtimeShell}
      ${pkgs.busybox}/bin/mkdir -p /run/wrappers/bin
      ${pkgs.busybox}/bin/ln -sfn ${desktop-pkgs.gnome-keyring}/bin/gnome-keyring-daemon /run/wrappers/bin/gnome-keyring-daemon
      true
    '';
  };

  # Let members of _video change the screen brightness (brightnessctl, the
  # brightness keys); on other distributions udev rules do this.
  targets.backlight.__assign = host-final.six.mkOneshot {
    up = pkgs.writeScript "backlight-up" ''
      #!${pkgs.runtimeShell}
      # the GPU driver may create the backlight a little after boot
      for _ in $(${pkgs.busybox}/bin/seq 100); do
        [ -e /sys/class/backlight ] && [ -n "$(${pkgs.busybox}/bin/ls /sys/class/backlight)" ] && break
        ${pkgs.busybox}/bin/sleep 0.1
      done
      for f in /sys/class/backlight/*/brightness; do
        [ -e "$f" ] || continue
        ${pkgs.busybox}/bin/chgrp _video "$f" && ${pkgs.busybox}/bin/chmod g+w "$f"
      done
      true
    '';
    passthru.after = [ host-final.targets.global.coldplug ];
  };

}

# the machine's own extra-config comes last, so it can change anything above
++ lib.toList (extra-config host-final))
