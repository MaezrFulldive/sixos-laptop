# The configuration that the automated test installs and boots in QEMU: the
# same nix/laptop.nix as a real laptop (settings in ../../testvm-settings.nix).
args@{ laptop-host, ... }:

laptop-host args (import ../../testvm-settings.nix)
