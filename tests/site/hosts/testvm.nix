# The configuration that the automated test boots in QEMU: the same
# nix/laptop.nix as a real laptop, with settings for the virtual hardware.
# It also uses the options the docs describe (a service from by-name/,
# extra-config, session-commands), so the test checks those too.
args@{ laptop-host, ... }:

laptop-host args {
  username = "tester";
  root-disk-modules = [ "nvme" ];     # QEMU emulates an NVMe disk, like most laptops
  console = { device = "ttyS0"; baud = 115200; };   # serial port, read by the test
  wifi = null;

  # sound, as docs/systemd-gaps.md describes it
  extra-packages = pkgs: with pkgs; [ pipewire wireplumber ];
  session-commands = [ "pipewire" "wireplumber" ];

  # a service of our own (by-name/ea/earlyoom)
  extra-config = host: {
    targets.earlyoom.__assign = host.services.earlyoom { };
  };
}
