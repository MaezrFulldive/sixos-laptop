{ writeShellApplication
, coreutils
, util-linux
, parted
, dosfstools
, e2fsprogs
, openssl
, openssh
, grub2_efi
, efibootmgr
, nix
, gnugrep
, gnused
, gnutar
}:

writeShellApplication {
  name = "sixos-install";
  runtimeInputs = [
    coreutils
    util-linux
    parted
    dosfstools
    e2fsprogs
    openssl
    openssh
    grub2_efi
    efibootmgr
    nix
    gnugrep
    gnused
    gnutar
  ];
  text = builtins.readFile ./sixos-install.sh;
}
