# The D-Bus *system* bus (/run/dbus/system_bus_socket).  NetworkManager and
# wpa_supplicant talk over it; so do bluez, upower, udisks and friends, if you
# add them.
#
# Differences from a systemd distribution:
#   - no bus activation: every service on the bus is an s6 service of its own
#     (listed in `after` of the service that needs it)
#   - it runs as root: sixos has no `messagebus` user
#   - only the policies of `packages` are loaded (their share/dbus-1/system.d),
#     so the bus can't be opened up by whatever happens to be installed
{ lib, pkgs, six, targets
, package ? (import ../../../nix/sources.nix).desktop-pkgs.dbus
, packages ? [ ]   # e.g. [ networkmanager wpa_supplicant ]
, after ? [ ]
}:
let
  policies = lib.concatMapStrings (p: ''
    <includedir>${p}/share/dbus-1/system.d</includedir>
  '') ([ package ] ++ packages);

  # dbus's own system.conf, minus <user>, <fork>, <pidfile>, bus activation
  # and the /etc includes
  config = pkgs.writeText "dbus-system.conf" ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>system</type>
      <listen>unix:path=/run/dbus/system_bus_socket</listen>
      <auth>EXTERNAL</auth>
      <policy context="default">
        <allow user="*"/>
        <deny own="*"/>
        <deny send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_requested_reply="true" send_type="method_return"/>
        <allow send_requested_reply="true" send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
        <allow receive_type="signal"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Introspectable"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Properties"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Containers1"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus" send_member="UpdateActivationEnvironment"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Debug.Stats"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.systemd1.Activator"/>
      </policy>
      <policy user="root">
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Monitoring"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Debug.Stats"/>
      </policy>
    ${policies}
    </busconfig>
  '';

  notification-fd = 3;
in
six.mkFunnel {
  inherit notification-fd;
  run = pkgs.writeScript "dbus-system-run" ''
    #!${pkgs.runtimeShell}
    exec 2>&1
    ${pkgs.busybox}/bin/mkdir -p /run/dbus
    # dbus (and NetworkManager) want a machine id; make one on first boot
    ${package}/bin/dbus-uuidgen --ensure=/etc/machine-id
    # --print-address writes the address and a newline to fd 3 once the
    # socket is listening, which is exactly s6's readiness notification
    exec ${package}/bin/dbus-daemon --nofork --nopidfile --nosyslog \
      --config-file=${config} --print-address=${toString notification-fd}
  '';
  passthru.after = [ targets.mounts."" ] ++ after;
}
