# Settings of the test machine (tests/site/hosts/testvm.nix): nix/laptop.nix
# with settings for the virtual hardware.  They also use the options the
# docs describe (a service from by-name/, extra-config, session-commands),
# so the test checks those too.
{
  username = "tester";
  root-disk-modules = [ "nvme" ];     # QEMU emulates an NVMe disk, like most laptops
  console = { device = "ttyS0"; baud = 115200; };   # serial port, read by the test
  desktop = true;
  qutebrowser = true;

  # a session program of our own (sound is always started)
  session-commands = [ "sleep 100000" ];

  # a service of our own (by-name/ea/earlyoom)
  extra-config = host: {
    targets.earlyoom.__assign = host.services.earlyoom { };
  };
}
