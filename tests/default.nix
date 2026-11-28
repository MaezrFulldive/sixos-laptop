# Automated tests.  Run them all with:
#
#   nix-build tests -A all
#
# 1. `install`: runs scripts/install-on-live-usb (the command README.md tells
#    you to run on the live USB) inside a throwaway VM, twice:
#      a. onto an empty virtual disk, answering every question with flags:
#         it erases the disk, writes a host file, adds a Wi-Fi network
#      b. again onto the same disk, reusing it (--keep), after adding a file
#         to /home and an old-style iwd Wi-Fi network: these must survive,
#         the iwd network must become a NetworkManager one, and the
#         passwords must be kept
#    The system is the prebuilt test system (building it needs the
#    network), so only the build step itself is skipped.
# 2. `boot`: boots that disk in QEMU with UEFI firmware, an NVMe drive and a
#    network card, like a laptop, and checks over the serial console that
#      - GRUB, the kernel, the initrd and s6 come up and print `login:`
#      - root and the user can log in with their passwords (/etc/shadow)
#      - doas asks for a password, accepts the right one, rejects a wrong one
#      - the services are up; NetworkManager configures the network card
#        by DHCP and knows both Wi-Fi networks
#      - logging in through ly (typed on the virtual keyboard) starts mango,
#        with sound, portals, the keyring, the clipboard history ...
#      - poweroff powers the machine off (rather than rebooting it)
#    It saves the serial log and a screenshot in its output.
# 3. `generated-host`: the host file the installer wrote in 1a evaluates.
#
# The test machine is tests/site/hosts/testvm.nix: nix/laptop.nix with
# settings for the virtual hardware.
{ }:

let
  repo = import ../. { site-dir = ./site; };
  inherit (repo.sources) desktop-pkgs;
  pkgs = desktop-pkgs;
  inherit (pkgs) lib;

  host = repo.hosts.testvm;
  system = host.configuration;
  username = "tester";

  root-password = "sixosroot";
  user-password = "sixosuser";

  # nixpkgs' VM helper, with the modules the installer needs (FAT for the
  # ESP, and code pages for mounting it)
  vmTools = pkgs.vmTools.override {
    rootModules = [
      "virtio_pci" "virtio_mmio" "virtio_blk" "virtio_balloon" "virtio_rng"
      "ext4" "virtiofs" "crc32c"
      "vfat" "nls_cp437" "nls_iso8859_1"
    ];
  };

  install = vmTools.runInLinuxVM (pkgs.runCommand "sixos-test-install" {
    # what the NixOS live USB has
    nativeBuildInputs = with pkgs; [
      nix openssl bash gnutar util-linux gawk gnused gnugrep coreutils findutils
    ];
    closure = pkgs.closureInfo { rootPaths = [ system repo.installer ]; };
    memSize = 2048;
    preVM = ''
      mkdir -p $out
      diskImage=$out/disk.qcow2
      ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 $diskImage 16G
    '';
  } ''
    set -euxo pipefail
    # A Nix database for the store paths the VM can see, so that the
    # installer's `nix copy` works (the same trick nixpkgs' make-disk-image uses)
    export HOME=$TMPDIR
    export NIX_STATE_DIR=$TMPDIR/state
    nix-store --load-db < $closure/registration
    export NIX_CONFIG="substituters ="   # nothing to download from in the sandbox

    # a stand-in for the repository, with a result link that must not be copied
    R=$TMPDIR/sixos-laptop
    mkdir -p $R/scripts $R/site/hosts
    cp ${../scripts/install-on-live-usb} $R/scripts/install-on-live-usb
    cp ${../pins.json} $R/pins.json
    cp ${./site/hosts/testvm.nix} $R/site/hosts/testvm.nix
    ln -s /nix/store/does-not-exist $R/result
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForTheAutomatedTestOnly test" > $TMPDIR/key.pub
    common="--yes --disk /dev/vda --no-nvram --installer ${repo.installer} --system ${system}"

    # a. a new install
    SIXOS_ROOT_PASSWORD_HASH=$(openssl passwd -6 -salt sixostest ${root-password}) \
    SIXOS_USER_PASSWORD_HASH=$(openssl passwd -6 -salt sixostest ${user-password}) \
    SIXOS_WIFI_PASSPHRASE=test-passphrase \
      bash $R/scripts/install-on-live-usb $common --erase \
        --host gen --user ${username} --desktop --qutebrowser \
        --wifi TestNet --ssh-key $TMPDIR/key.pub
    cp $R/site/hosts/gen.nix $out/gen.nix

    # what an older install would have left behind
    mount /dev/vda2 /mnt
    echo kept > /mnt/home/${username}/keep-me
    mkdir -p /mnt/etc/iwd/networks
    printf '[Security]\nPassphrase=old-passphrase\n' > /mnt/etc/iwd/networks/OldNet.psk
    umount /mnt

    # b. reinstall, reusing the disk (no password hashes given: they must
    # come from the first install)
    bash $R/scripts/install-on-live-usb $common --keep --keep-passwords \
      --host testvm --use-host-file --no-wifi

    # the reused disk
    mount /dev/vda2 /mnt
    test "$(cat /mnt/home/${username}/keep-me)" = kept
    test ! -e /mnt/etc/iwd
    grep -q '^psk=old-passphrase$' /mnt/etc/NetworkManager/system-connections/OldNet.nmconnection
    grep -q '^psk=test-passphrase$' /mnt/etc/NetworkManager/system-connections/TestNet.nmconnection
    ls -d /mnt/home/${username}/sixos-laptop.old-*
    umount /mnt
    echo "### ok: the reinstall kept /home and the Wi-Fi networks"
  '');

  # The host file the installer wrote must evaluate.  (Evaluating it means
  # reading the install's output, i.e. import-from-derivation.)
  generated-site = pkgs.runCommand "sixos-test-generated-site" { } ''
    cp -r ${./site} $out
    chmod -R u+w $out
    rm $out/hosts/*
    cp ${install}/gen.nix $out/hosts/gen.nix
  '';
  # sixos reads a site only from a path value; reading a file from the
  # build output first makes Nix build it (import-from-derivation)
  generated-site-path = builtins.seq
    (builtins.readFile "${generated-site}/hosts/gen.nix")
    (/. + builtins.unsafeDiscardStringContext "${generated-site}");
  generated-host = pkgs.writeText "sixos-test-generated-host-evaluates"
    (builtins.unsafeDiscardOutputDependency
      (import ../. { site-dir = generated-site-path; }).hosts.gen.configuration.drvPath);

  boot = pkgs.runCommand "sixos-test-boot" {
    nativeBuildInputs = [ pkgs.qemu_kvm pkgs.python3 ];
    requiredSystemFeatures = [ "kvm" ];
    passthru = { inherit install system; };
  } ''
    mkdir -p $out
    qemu-img create -f qcow2 -F qcow2 -b ${install}/disk.qcow2 disk.qcow2
    python3 ${./boot-test.py} \
      --qemu ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
      --ovmf ${pkgs.OVMF.fd}/FV/OVMF.fd \
      --disk disk.qcow2 \
      --out $out \
      --user ${username} \
      --uid ${toString host.users.${username}.uid} \
      --root-password ${root-password} \
      --user-password ${user-password}
  '';

in
{
  inherit install boot system generated-host;

  # the real laptop configuration must evaluate and build too
  laptop = (import ../. { }).hosts.laptop.configuration;

  all = pkgs.linkFarm "sixos-laptop-tests" {
    boot = boot;
    generated-host = generated-host;
    laptop = (import ../. { }).hosts.laptop.configuration;
  };
}
