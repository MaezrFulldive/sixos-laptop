# Several machines in one repository

One repository can describe all your machines. Each machine is one file in
`site/hosts/`, and the file name is its host name:

```
site/hosts/laptop.nix     ->  nix-build -A hosts.laptop.configuration
site/hosts/desktop.nix    ->  nix-build -A hosts.desktop.configuration
```

Settings can be shared at three levels, from most to least common:

| shared by | where | NixOS equivalent |
| --- | --- | --- |
| every machine that uses this setup | `nix/laptop.nix` | a `common.nix` every host imports |
| some machines ("roles") | `nix/roles/<role>.nix`, listed in each host's `extra-config` | `imports = [ ./roles/gaming.nix ]` |
| every machine, unconditionally | `site/overlay.nix` | |

## Add a machine

Create `site/hosts/desktop.nix`:

```nix
args@{ laptop-host, ... }:

laptop-host args {
  username = "me";
  root-disk-modules = [ "ahci" "sd_mod" ];   # SATA disk
  desktop = true;
  extra-packages = pkgs: with pkgs; [ firefox ];
}
```

`laptop-host` is `nix/laptop.nix`: network, doas, the kernel, the base
services and (with `desktop = true`) ly and mango, with the per-machine
settings as arguments (they're listed and explained at the top of that
file). Despite the name, nothing in it is laptop-only. A server is
`desktop = false`.

Or let the installer write the file: run it on the new machine's live USB
and answer `desktop` to the host-name question (or pass `--host desktop`).

Later updates work as on the laptop: `sixos-rebuild switch` builds the
configuration named after the machine's host name.

## Machine-specific extras: `extra-config`

For things that aren't one of `laptop-host`'s settings, give the machine an
`extra-config`: infusions ([what's an infusion](sixos-for-nixos-users.md#infusions-instead-of-modules))
applied after everything in `nix/laptop.nix`, so they can add to or change
anything in it. `host` is the finished host (sixos's `host-final`):

```nix
  extra-config = host: {
    # a service: sixos's own, or one from this repository's by-name/
    targets.earlyoom.__assign = host.services.earlyoom { };

    # a kernel parameter
    boot.kernel.params.__append = [ "mem_sleep_default=deep" ];

    # an /etc/hosts entry
    etc.hosts."192.168.1.10".__assign = [ "nas" ];
  };
```

## Roles: settings shared by some machines

A role is a file holding an `extra-config` function. Several machines list
it, which is what `imports` does on NixOS. `nix/roles/gaming.nix`:

```nix
host:
let
  desktop-pkgs = (import ../sources.nix).desktop-pkgs;
in {
  # programs: add them to `sw`, the system's package list
  sw.__input.paths.__append = with desktop-pkgs; [ mangohud gamemode ];

  targets.earlyoom.__assign = host.services.earlyoom { min-free-percent = 10; };
}
```

Each machine that has the role lists it (several roles, in order):

```nix
  extra-config = host: [
    (import ../../nix/roles/gaming.nix host)
    (import ../../nix/roles/dev.nix host)
    { boot.kernel.params.__append = [ "quiet" ]; }   # this machine only
  ];
```

The order matters: when two roles set the same thing, the later one wins
(there are no priorities like `mkForce`). `__append` from several roles all
add up.

`sw.__input.paths.__append` is how a role adds programs, because a host's
`extra-packages` is only one setting. Programs from `desktop-pkgs` come
prebuilt; `host.pkgs` is the older nixpkgs of the base system (see
[sixos-for-nixos-users.md](sixos-for-nixos-users.md#how-this-repository-fits-around-sixos)).

## Every machine: `site/overlay.nix`

`site/overlay.nix` is a list of overlays over the whole site (all hosts at
once). With `infuse` and `__values` ("each host"), something for every
machine looks like this:

```nix
{ infuse, ... }: [
  (site-final: site-prev: infuse site-prev {
    hosts.__values.etc.hosts."192.168.1.10".__assign = [ "nas" ];
  })
]
```

Usually it's simpler to put shared things in `nix/laptop.nix`. The overlay
is for machines that don't use `laptop-host` at all (say, a server written
from scratch), or for things that need to see every host, such as each
host's address for the others' `/etc/hosts`:
`site-final.hosts.<name>` is any other machine.

## Tags

sixos has a built-in mechanism for per-hardware settings: **tags**. A host
sets a tag to true and gets that tag's overlays. `nix/laptop.nix` uses
`tags.is-bootloader-grub` (which makes `deploy` copy the kernel and initrd
to the EFI partition). sixos's own tags are in its `tags/` directory (CPU
architectures, bootloaders, Apple Silicon...). You can define your own in
`site/tags.nix`, but for your own groupings, roles (above) are simpler.

## Pushing updates from one machine to another

Building on your fastest machine and copying the result to the others
needs `sshd = true` on the receiving machine and an ssh key in its
`/root/.ssh/authorized_keys` (the installer's `--ssh-key` puts one there):

```sh
nix-build -A hosts.desktop.configuration
nix copy --no-check-sigs --to ssh://root@desktop ./result
ssh root@desktop "$(readlink -f result)/bin/deploy"
```
