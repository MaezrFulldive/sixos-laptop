# Every external source this repo uses, read from ../pins.json.
#
# pins.json is rewritten by scripts/update-pins.sh (run weekly by
# .github/workflows/update.yml), so nothing in here should hard-code a URL,
# revision or hash.
let
  pins = builtins.fromJSON (builtins.readFile ../pins.json);

  # Upstream sixos, unmodified
  sixos-upstream = builtins.fetchTarball {
    name = "sixos-upstream";
    url = "${pins.sixos.url}/archive/${pins.sixos.rev}.tar.gz";
    inherit (pins.sixos) sha256;
  };

  # The nixpkgs revision upstream sixos pins in its own default.nix.  Used for
  # the base system (s6, s6-rc, busybox, doas, nix).
  nixpkgs-path = builtins.fetchTarball {
    name = "nixpkgs-base";
    inherit (pins.nixpkgs-base) url sha256;
  };

  # A current NixOS release.  Used for the kernel, firmware, ly, mango, the
  # desktop programs, and the installer/test tools.
  nixpkgs-desktop-path = builtins.fetchTarball {
    name = "nixpkgs-desktop";
    url = "${pins.nixpkgs-desktop.url}/archive/${pins.nixpkgs-desktop.rev}.tar.gz";
    inherit (pins.nixpkgs-desktop) sha256;
  };

  desktop-pkgs = import nixpkgs-desktop-path {
    localSystem = "x86_64-linux";
    config = { };
    overlays = [ ];
  };

  # Upstream sixos plus the patches in ../patches/sixos, applied in file-name
  # order.  If upstream changes so much that a patch no longer applies, this
  # derivation fails and so does CI.
  patch-dir = ../patches/sixos;
  sixos-path = desktop-pkgs.applyPatches {
    name = "sixos-patched";
    src = sixos-upstream;
    patches = map (name: patch-dir + "/${name}")
      (builtins.sort builtins.lessThan
        (builtins.filter (name: builtins.match ".*\\.patch" name != null)
          (builtins.attrNames (builtins.readDir patch-dir))));
  };
in
{
  inherit pins sixos-upstream sixos-path nixpkgs-path nixpkgs-desktop-path desktop-pkgs;
}
