# The configuration that the automated test boots in QEMU: the same
# nix/laptop.nix as a real laptop, with settings for the virtual hardware.
args@{ laptop-host, ... }:

laptop-host args {
  username = "tester";
  root-disk-modules = [ "nvme" ];     # QEMU emulates an NVMe disk, like most laptops
  console = { device = "ttyS0"; baud = 115200; };   # serial port, read by the test
  wifi = null;
}
