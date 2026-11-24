# Your laptop.  The file name ("laptop") is the host name.
#
# Change the values marked CHANGE ME (README.md, step 2 shows how to find
# them).  Everything else lives in ../../nix/laptop.nix.
args@{ laptop-host, ... }:

laptop-host args {

  username = "me";                                   # CHANGE ME

  # "nvme" for an NVMe SSD, "ahci" for a SATA disk   # CHANGE ME
  root-disk-modules = [ "nvme" ];

  wifi = {
    module = "iwlwifi";                              # CHANGE ME
    sysfs = "/sys/devices/pci0000:00/0000:00:14.3";  # CHANGE ME
  };

  # More programs, from nixpkgs (search on https://search.nixos.org/packages):
  # extra-packages = pkgs: with pkgs; [ firefox ];

  # Extra ly settings, see https://codeberg.org/fairyglade/ly (res/config.ini):
  # ly-settings = { animation = "matrix"; bigclock = "en"; };
}
