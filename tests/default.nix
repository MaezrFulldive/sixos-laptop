# Automated tests.  Run them all with:
#
#   nix-build tests -A all
#
# 1. `install`: runs scripts/install-over-ssh (the command README.md tells
#    you to run, which runs installer/sixos-install.sh on the laptop) inside a
#    throwaway VM, onto an empty virtual disk.  `ssh` is replaced by a stand-in
#    that runs the "laptop" side in the same VM, so everything else is real:
#    the Nix ssh copies, both installer phases and the repository copy.
# 2. `boot`: boots that disk in QEMU with UEFI firmware and an NVMe drive, like
#    a laptop, and checks over the serial console that:
#      - GRUB, the kernel, the initrd and s6 come up and print `login:`
#      - root and the user can log in with their passwords (/etc/shadow)
#      - doas asks for a password, accepts the right one, rejects a wrong one
#      - ly, seatd, run-user and dnscache are running
#      - logging in through ly (typed on the virtual keyboard) starts mango
#      - poweroff powers the machine off (rather than rebooting it)
#    It saves the serial log and a screenshot in its output.
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

  # Stands in for ssh: skips the options and the host name, then runs the
  # command with bash, like the live USB's root shell would.
  fake-ssh = pkgs.writeShellScriptBin "ssh" ''
    host=
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift; break ;;
        -[bcDEeFIiJLlmOopQRSWw]) shift 2 ;;   # options that take an argument
        -*) shift ;;
        *) if [ -z "$host" ]; then host=$1; shift; else break; fi ;;
      esac
    done
    [ $# -gt 0 ] || exit 0    # e.g. `ssh -O exit host`
    echo "(fake ssh to $host) $*" >&2
    exec ${pkgs.bash}/bin/bash -c "$*"
  '';

  install = vmTools.runInLinuxVM (pkgs.runCommand "sixos-test-install" {
    nativeBuildInputs = [ fake-ssh pkgs.nix pkgs.openssl pkgs.bash pkgs.gnutar ];
    closure = pkgs.closureInfo { rootPaths = [ system repo.installer ]; };
    memSize = 2048;
    preVM = ''
      mkdir -p $out
      diskImage=$out/disk.qcow2
      ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 $diskImage 16G
    '';
  } ''
    # A Nix database for the store paths the VM can see, so that the
    # installer's `nix copy` works (the same trick nixpkgs' make-disk-image uses)
    export HOME=$TMPDIR
    export NIX_STATE_DIR=$TMPDIR/state
    nix-store --load-db < $closure/registration

    export SIXOS_ROOT_PASSWORD_HASH=$(openssl passwd -6 -salt sixostest ${root-password})
    export SIXOS_USER_PASSWORD_HASH=$(openssl passwd -6 -salt sixostest ${user-password})

    # nothing to download from in the sandbox
    export NIX_CONFIG="substituters ="

    # a stand-in for the repository, with a result link that must not be copied
    mkdir -p $TMPDIR/sixos-laptop/scripts
    cp ${../scripts/install-over-ssh} $TMPDIR/sixos-laptop/scripts/install-over-ssh
    cp ${../pins.json} $TMPDIR/sixos-laptop/pins.json
    ln -s /nix/store/does-not-exist $TMPDIR/sixos-laptop/result

    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForTheAutomatedTestOnly test" > $TMPDIR/key.pub

    bash $TMPDIR/sixos-laptop/scripts/install-over-ssh fakehost \
      --disk /dev/vda --user ${username} --ssh-key $TMPDIR/key.pub \
      --system ${system} --installer ${repo.installer} \
      --yes --no-nvram
  '');

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
  inherit install boot system;

  # the real laptop configuration must evaluate and build too
  laptop = (import ../. { }).hosts.laptop.configuration;

  all = pkgs.linkFarm "sixos-laptop-tests" {
    boot = boot;
    laptop = (import ../. { }).hosts.laptop.configuration;
  };
}
