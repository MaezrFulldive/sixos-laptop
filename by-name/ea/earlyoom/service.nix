# earlyoom: when RAM and swap are nearly full, kill the biggest process
# instead of letting the whole laptop freeze.  https://github.com/rfjakob/earlyoom
#
# An example of a service of your own (docs/services.md).  sixos finds it
# because default.nix passes this repository's by-name/ directory to sixos;
# the directory layout (by-name/<first two letters>/<name>/service.nix) is
# the same as sixos's own by-name/.
#
# Turn it on in site/hosts/<machine>.nix:
#
#   extra-config = host: {
#     targets.earlyoom.__assign = host.services.earlyoom { };
#   };

# Arguments sixos fills in (like callPackage): the host's package set, the
# service constructors, and the host's other targets.
{ pkgs
, six
, targets

# Arguments you may set: host.services.earlyoom { min-free-percent = 10; }
, package ? pkgs.earlyoom
, min-free-percent ? 5   # act when both free RAM and free swap drop below this
, extra-args ? [ ]
}:

# A longrun: s6 starts the program, restarts it if it dies, and sends its
# output to /var/log/earlyoom/current.  The program must stay in the
# foreground (no daemonizing), which earlyoom does by default.
six.mkFunnel {
  run.argv = [
    "${package}/bin/earlyoom"
    "-m" (toString min-free-percent)
    "-s" (toString min-free-percent)
  ] ++ extra-args;

  # start only after /proc is mounted (earlyoom reads /proc/meminfo)
  passthru.after = [ targets.mounts.proc ];
}
