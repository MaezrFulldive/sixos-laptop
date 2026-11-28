# This machine's settings.  The file name ("laptop") is the host name.
# scripts/install-on-live-usb writes this file from your answers; change
# anything here, then run `sixos-rebuild switch` (docs/configuring.md).
# Everything else lives in ../../nix/laptop.nix.
args@{ laptop-host, ... }:

laptop-host args {

  username = "maezr";

  # kernel modules the initrd needs to find the root disk
  root-disk-modules = [ "nvme" ];

  # ly + mango and the desktop programs
  desktop = true;

  # qutebrowser, with mpv + yt-dlp, GStreamer, spell checking and pdf.js
  qutebrowser = true;

  # More programs, from nixpkgs (search on https://search.nixos.org/packages):
  # extra-packages = pkgs: with pkgs; [ firefox ];

  # Programs that run while you're logged in (docs/services.md):
  # session-commands = [ "mako" ];

  # Anything else, as infusions (docs/multiple-machines.md), e.g. a service:
  # extra-config = host: {
  #   targets.earlyoom.__assign = host.services.earlyoom { };
  # };

  # Run sshd, to push updates from another computer.
  # It adds one more package to compile (openssh).
  # sshd = true;

  # Extra ly settings, see https://codeberg.org/fairyglade/ly (res/config.ini):
  # ly-settings = { animation = "matrix"; bigclock = "en"; };
}
