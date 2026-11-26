# The sixos host configuration for a laptop with ly + mango.
#
# site/hosts/laptop.nix calls this with the settings that differ from laptop
# to laptop (user name, disk driver, Wi-Fi card).  The automated test calls it
# with settings for a QEMU virtual machine (tests/site/hosts/testvm.nix), so
# the test boots exactly this configuration.

# arguments sixos passes to every file in site/
{ lib, infuse, sources, ... }:

# settings, from site/hosts/<name>.nix
{ username
, uid ? 1000

  # kernel modules the initrd loads so the root disk appears:
  # "nvme" for NVMe disks, "ahci" for SATA
, root-disk-modules ? [ "nvme" ]

  # the console that shows kernel messages and the rescue `login:` prompt.
  # tty1 is used by ly.
, console ? { device = "tty2"; }

  # { module = "iwlwifi"; sysfs = "/sys/devices/pci0000:00/0000:00:14.3"; }
  # or null for no Wi-Fi
, wifi ? null

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
  #   [ "pipewire" "wireplumber" "pipewire-pulse" ]
  # (the programs themselves go in extra-packages).
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
  # sixos has no udevd (it uses mdevd), and nixpkgs' libinput/wlroots are
  # linked against systemd's libudev, which only reports devices that udevd
  # has processed, so mango would find no keyboard or mouse.  libudev-zero is
  # a drop-in libudev for exactly this situation (mdevd runs with `-O 4` to
  # rebroadcast hotplug events for it).  LD_LIBRARY_PATH overrides the
  # libraries' RUNPATH, so no rebuild is needed; programs started from mango
  # inherit it.
  #
  # ly starts the session's `Exec=` command, which is changed from `mango` to
  # `mango-session`: it gives the session a D-Bus session bus (there is no
  # systemd/logind to provide one; portals, notifications, pipewire and many
  # GTK/Qt programs expect it), starts `session-commands`, runs mango, and
  # stops those commands again when mango exits.
  dbus = desktop-pkgs.dbus;
  mango-session = desktop-pkgs.writeShellScript "mango-session" ''
    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      exec ${dbus}/bin/dbus-run-session \
        --dbus-daemon=${dbus}/bin/dbus-daemon \
        --config-file=${dbus}/share/dbus-1/session.conf -- "$0" "$@"
    fi
    # .desktop files (rofi -show drun), icons, D-Bus services ...  (ly sets
    # PATH from its own config but doesn't read /etc/profile)
    export XDG_DATA_DIRS=''${XDG_DATA_DIRS:-/run/current-system/sw/share}
    ${lib.concatMapStrings (cmd: "${cmd} &\n") session-commands}
    @out@/bin/mango "$@"
    status=$?
    # shellcheck disable=SC2046
    kill $(jobs -p) 2>/dev/null
    exit $status
  '';
  mango = desktop-pkgs.symlinkJoin {
    name = "mango-with-libudev-zero";
    paths = [ desktop-pkgs.mangowc ];
    nativeBuildInputs = [ desktop-pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/mango \
        --prefix LD_LIBRARY_PATH : ${desktop-pkgs.libudev-zero}/lib
      substitute ${mango-session} $out/bin/mango-session --subst-var out
      chmod +x $out/bin/mango-session
      for f in $out/share/wayland-sessions/*.desktop; do
        sed 's|^Exec=mango$|Exec=mango-session|' "$(readlink -f "$f")" > "$f.new"
        mv "$f.new" "$f"
      done
    '';
  };

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
      # required by sixos itself
      (with pkgs; [ busybox s6 s6-rc doas nix bashInteractive ])
      # desktop
      ++ [ mango ]
      ++ (with desktop-pkgs; [
        foot   # terminal   (mango default: Alt+Return)
        rofi   # launcher   (mango default: Alt+Space)
        mesa   # GPU drivers
        git
      ])
      ++ extra-packages desktop-pkgs;
  };

  # Files under /run/current-system/etc/.  The installer links /etc/pam.d,
  # /etc/mango and /etc/fonts to them once; /etc/profile is linked
  # automatically on first boot.
  extra-configuration-links.__assign = {
    "etc/pam.d" = pam-d;
    "etc/profile" = pkgs.writeText "profile" ''
      # /run/six/bin first: that's where the setuid-root doas lives
      export PATH=/run/six/bin:/run/current-system/sw/bin
      # .desktop files (rofi -show drun), icons, D-Bus services, man pages ...
      export XDG_DATA_DIRS=/run/current-system/sw/share
    '';
    "etc/mango/config.conf" = "${desktop-pkgs.mangowc.src}/assets/config.conf";
    "etc/fonts/fonts.conf" = desktop-pkgs.makeFontsConf {
      fontDirectories = with desktop-pkgs; [ dejavu_fonts noto-fonts ];
    };
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

  # DNS: a local caching resolver on 127.0.0.1.  It must be told where to
  # forward queries, otherwise evaluation fails.
  targets.dnscache.__assign = host-final.services.dnscache {
    forward-queries-to = [ "9.9.9.9" "1.1.1.1" ];
  };

  # compressed swap in RAM
  targets.zram.__assign = host-final.services.zram { size-percent = 50; };

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

}

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

] ++ lib.optional (wifi != null) {

  targets.wifi.__assign = host-final.services.eiwd {
    ifname = "wlan0"; # the name sixos gives the interface
    phyname = "phy-wifi";
    modules = [ wifi.module ];
    sysfs-base-glob = wifi.sysfs;
    state_directory = "/etc/iwd/networks";
    conf_directory = "/etc/iwd";
  };

}

# the machine's own extra-config comes last, so it can change anything above
++ lib.toList (extra-config host-final))
