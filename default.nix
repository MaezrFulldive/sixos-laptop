# Entry point.
#
#   nix-build -A hosts.laptop.configuration   # the system for your laptop
#   nix-build -A installer                    # the install script (run on the live USB)
#   nix-build tests -A all                    # the automated tests (see tests/default.nix)
#
{ site-dir ? ./site }:

let
  sources = import ./nix/sources.nix;

  site = import sources.sixos-path {
    inherit (sources) nixpkgs-path;
    inherit site-dir;

    # The final type check refers to a `site` type that sixos's types/ does
    # not define, so it is turned off.
    check-types = false;

    # Services of our own, next to sixos's (docs/services.md)
    extra-by-name-dirs = [ ./by-name ];

    # Extra arguments available to every file under site/
    extra-auto-args = {
      inherit sources;
      laptop-host = import ./nix/laptop.nix;
    };
  };
in
{
  inherit sources site;
  inherit (site) hosts;   # lazy: building the installer doesn't evaluate the site
  installer = sources.desktop-pkgs.callPackage ./installer { };
}
