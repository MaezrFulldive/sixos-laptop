# The same machine after its owner added a program: the test switches the
# running testvm to this with `deploy`, as `sixos-rebuild switch` does, and
# checks that the program is then in PATH and in the launcher.
args@{ laptop-host, ... }:

laptop-host args (import ../../testvm-settings.nix // {
  extra-packages = pkgs: [ pkgs.helix ];
})
