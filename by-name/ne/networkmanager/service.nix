# NetworkManager: Wi-Fi and wired networks, DHCP and /etc/resolv.conf.
# Use it with `nmtui` or `nmcli`.  Connections are files in
# /etc/NetworkManager/system-connections/ (they survive updates), and extra
# settings can go in /etc/NetworkManager/conf.d/*.conf without a rebuild.
#
# Differences from a systemd distribution:
#   - no polkit: `auth-polkit = false` lets every local user change the
#     network (like a desktop session on NixOS, without a password prompt).
#     Set it to "root-only" to require doas.
#   - no udevd: NetworkManager uses libudev-zero (via LD_LIBRARY_PATH), which
#     reads devices straight from /sys and mdevd's uevents.  libudev-zero
#     only lists devices that have a /dev node, so network interfaces (which
#     have none) are added to its list here; without that, NetworkManager
#     sees every interface as "unmanaged".  (A few seconds' compile.)
#   - no dispatcher scripts, no VPN plugins
{ lib, pkgs, six, targets
, package ? desktop-pkgs.networkmanager
, libudev-zero ? desktop-pkgs.libudev-zero.overrideAttrs (old: {
    pname = "libudev-zero-with-net";
    postPatch = (old.postPatch or "") + ''
      substituteInPlace udev_enumerate.c \
        --replace-fail '{ "/sys/dev/block", "/sys/dev/char", NULL }' \
                       '{ "/sys/dev/block", "/sys/dev/char", "/sys/class/net", NULL }'
    '';
  })
, settings ? { }   # merged into NetworkManager.conf, e.g. { main.dns = "none"; }
, after ? [ ]      # the D-Bus system bus and wpa_supplicant
, desktop-pkgs ? (import ../../../nix/sources.nix).desktop-pkgs
}:
let
  conf = pkgs.writeText "NetworkManager.conf" (lib.generators.toINI { } (lib.recursiveUpdate {
    main = {
      plugins = "keyfile";
      dhcp = "internal";
      dns = "default";         # use the DNS servers DHCP hands out ...
      rc-manager = "file";     # ... and write them to /etc/resolv.conf
      auth-polkit = "false";
      hostname-mode = "none";  # the host name comes from the configuration
    };
    logging.level = "INFO";
    device."wifi.backend" = "wpa_supplicant";
  } settings));
in
six.mkFunnel {
  run = pkgs.writeScript "networkmanager-run" ''
    #!${pkgs.runtimeShell}
    exec 2>&1
    ${pkgs.busybox}/bin/mkdir -p /var/lib/NetworkManager /etc/NetworkManager/conf.d
    ${pkgs.busybox}/bin/mkdir -p -m 0700 /etc/NetworkManager/system-connections
    export LD_LIBRARY_PATH=${libudev-zero}/lib
    exec ${package}/bin/NetworkManager --no-daemon --config=${conf}
  '';
  passthru.after = [ targets.global.coldplug ] ++ after;
}
