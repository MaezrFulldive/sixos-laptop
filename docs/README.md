# Using sixos

The [main README](../README.md) covers installing. These pages cover living
with the result:

| page | read it when |
| --- | --- |
| [Configuring this machine](configuring.md) | you want to add a program, change a setting, look at a service or its logs, roll back |
| [sixos for NixOS users](sixos-for-nixos-users.md) | you know NixOS and want to know what's different: no modules, *infusions* instead; hosts, services, targets |
| [Several machines](multiple-machines.md) | you want a second laptop or a desktop in the same repository, with shared settings |
| [Services, and what to do without systemd](services.md) | a program needs a daemon, or expects systemd, logind, udev or D-Bus |

The short version:

```sh
doas vim /etc/sixos/site/hosts/laptop.nix   # change something
sixos-rebuild switch                      # build it, switch to it, boot it from now on
```
