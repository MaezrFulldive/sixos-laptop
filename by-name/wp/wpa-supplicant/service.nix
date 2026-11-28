# wpa_supplicant without a config file: NetworkManager tells it, over the
# D-Bus system bus, which Wi-Fi interfaces to use and which network to join.
{ lib, pkgs, six, targets
, package ? (import ../../../nix/sources.nix).desktop-pkgs.wpa_supplicant
, after ? [ ]    # the D-Bus system bus
}:
six.mkFunnel {
  run = pkgs.writeScript "wpa-supplicant-run" ''
    #!${pkgs.runtimeShell}
    exec 2>&1
    exec ${package}/bin/wpa_supplicant -u
  '';
  passthru.after = after;
}
