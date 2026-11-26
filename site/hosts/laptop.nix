# Your laptop.  The file name ("laptop") is the host name.
#
# Change the values marked CHANGE ME (README.md, step 2 shows how to find
# them).  Everything else lives in ../../nix/laptop.nix.
args@{ laptop-host, ... }:

laptop-host args {

  username = "maezr";                                   # CHANGE ME

  # "nvme" for an NVMe SSD, "ahci" for a SATA disk   # CHANGE ME
  root-disk-modules = [ "nvme" ];

  wifi = {
    module = "iwlwifi";                              # CHANGE ME
    sysfs = "/sys/devices/pci0000:00/0000:00:1c.2/0000:3b:00.0";  # CHANGE ME
  };

  # More programs, from nixpkgs (search on https://search.nixos.org/packages):
  # extra-packages = pkgs: with pkgs; [ firefox ];

  # Programs that run while you're logged in (docs/services.md), e.g. sound
  # (also add pipewire and wireplumber to extra-packages):
  # session-commands = [ "pipewire" "wireplumber" "pipewire-pulse" ];

  # Anything else, as infusions (docs/multiple-machines.md), e.g. a service:
  # extra-config = host: {
  #   targets.earlyoom.__assign = host.services.earlyoom { };
  # };

  # Run sshd, to push updates from another computer (README.md step 6).
  # It adds one more package to compile (openssh).
  # sshd = true;

  # Extra ly settings, see https://codeberg.org/fairyglade/ly (res/config.ini):
  # ly-settings = { animation = "matrix"; bigclock = "en"; };
}
