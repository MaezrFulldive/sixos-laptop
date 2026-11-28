# The desktop: mango, started by ly, and the programs mango's defaults are
# made for.  nix/laptop.nix uses this when `desktop = true`.
#
# What is set up, and where:
#   - mango-session (below) runs the session: environment, a D-Bus session
#     bus, sound (PipeWire), `session-commands`, then mango
#   - /etc/mango/config.conf is mango's default config plus one line,
#     `source=/etc/mango/sixos.conf`, which adds the clipboard, screenshot and
#     media keys (sixos-conf below).  Keep that line if you copy the config to
#     ~/.config/mango/, and these keep working and updating.
#   - portals (screen sharing, screenshots, file pickers, secrets) and the
#     keyring start on demand over D-Bus; the files that say which portal
#     does what are in sw/etc/xdg (XDG_CONFIG_DIRS)
{ lib
, desktop-pkgs
, ca-file            # the https certificates
, session-commands   # the host's extra session programs
, qutebrowser        # include qutebrowser and its helpers
}:

let
  p = desktop-pkgs;
  dbus = p.dbus;
  sw = "/run/current-system/sw";

  # Set before the session bus starts, so everything it starts on demand
  # (portals, the keyring) gets the same environment.  (ly sets PATH from its
  # own config and doesn't read /etc/profile.)
  session-env = {
    XDG_DATA_DIRS = "${sw}/share";          # .desktop files, icons, D-Bus services
    XDG_CONFIG_DIRS = "${sw}/etc/xdg";      # portal choices, default applications
    XDG_CURRENT_DESKTOP = "mango";
    XDG_SESSION_TYPE = "wayland";
    NIX_XDG_DESKTOP_PORTAL_DIR = "${sw}/share/xdg-desktop-portal/portals";
    GST_PLUGIN_SYSTEM_PATH_1_0 = "${sw}/lib/gstreamer-1.0";
    SSL_CERT_FILE = ca-file;
    NIX_SSL_CERT_FILE = ca-file;
    EDITOR = "vim";
    TERMINAL = "foot";                      # for launchers starting terminal programs
  } // lib.optionalAttrs qutebrowser {
    BROWSER = "qutebrowser";
  };

  # PipeWire, then (once its socket exists) the session manager and the
  # PulseAudio server; all three stop when the session ends.
  sixos-audio = p.writeShellScript "sixos-audio" ''
    trap 'kill $(jobs -p) 2>/dev/null' EXIT TERM INT
    ${p.pipewire}/bin/pipewire &
    for _ in $(seq 50); do
      [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break
      sleep 0.1
    done
    ${p.wireplumber}/bin/wireplumber &
    ${p.pipewire}/bin/pipewire-pulse &
    wait
  '';

  # ly starts the session's `Exec=` command, which is changed from `mango` to
  # `mango-session`.  There is no systemd/logind to provide a session bus or
  # user services, so this does it: everything started here runs as you and
  # is stopped when mango exits.
  mango-session = p.writeShellScript "mango-session" ''
    ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") session-env)}
    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      exec ${dbus}/bin/dbus-run-session \
        --dbus-daemon=${dbus}/bin/dbus-daemon \
        --config-file=${dbus}/share/dbus-1/session.conf -- "$0" "$@"
    fi
    ${sixos-audio} &
    ${lib.concatMapStrings (cmd: "${cmd} &\n") session-commands}
    @out@/bin/mango "$@"
    status=$?
    # shellcheck disable=SC2046
    kill $(jobs -p) 2>/dev/null
    exit $status
  '';

  # sixos has no udevd (it uses mdevd), and nixpkgs' libinput/wlroots are
  # linked against systemd's libudev, which only reports devices that udevd
  # has processed, so mango would find no keyboard or mouse.  libudev-zero is
  # a drop-in libudev for exactly this situation (mdevd runs with `-O 4` to
  # rebroadcast hotplug events for it).  LD_LIBRARY_PATH overrides the
  # libraries' RUNPATH, so no rebuild is needed; programs started from mango
  # inherit it.
  mango = p.symlinkJoin {
    name = "mango-with-libudev-zero";
    paths = [ p.mangowc ];
    nativeBuildInputs = [ p.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/mango \
        --prefix LD_LIBRARY_PATH : ${p.libudev-zero}/lib
      substitute ${mango-session} $out/bin/mango-session --subst-var out
      chmod +x $out/bin/mango-session
      for f in $out/share/wayland-sessions/*.desktop; do
        sed 's|^Exec=mango$|Exec=mango-session|' "$(readlink -f "$f")" > "$f.new"
        mv "$f.new" "$f"
      done
    '';
  };

  # Print: freeze the screen, select an area, annotate it in satty (saved to
  # ~/Pictures/Screenshots, Ctrl+C copies)
  sixos-screenshot = p.writeShellApplication {
    name = "sixos-screenshot";
    runtimeInputs = with p; [ grim slurp wayfreeze satty wl-clipboard coreutils procps ];
    text = ''
      dir=''${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots
      mkdir -p "$dir"
      tmp=$(mktemp /tmp/screenshot.XXXXXX)
      trap 'rm -f "$tmp"' EXIT
      # wayfreeze shows a still image of the screen while slurp selects
      wayfreeze --hide-cursor \
        --after-freeze-cmd "grim -g \"\$(slurp)\" '$tmp'; pkill -x wayfreeze" || true
      [ -s "$tmp" ] || exit 0    # selection cancelled with Escape
      satty --filename "$tmp" \
        --output-filename "$dir/$(date +%Y-%m-%d_%H-%M-%S).png" \
        --copy-command wl-copy --early-exit
    '';
  };

  sixos-conf = p.writeText "mango-sixos.conf" ''
    # Added by sixos-laptop (nix/desktop.nix), through the `source=` line at
    # the end of /etc/mango/config.conf.

    # let portals (started on demand over D-Bus) find the compositor
    exec-once=dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
    # keep the clipboard when the program it was copied from closes ...
    exec-once=wl-clip-persist --clipboard regular
    # ... and remember it: Super+V picks an older entry
    exec-once=wl-paste --type text --watch cliphist store
    exec-once=wl-paste --type image --watch cliphist store
    bind=SUPER,v,spawn_shell,cliphist list | rofi -dmenu -p clipboard | cliphist decode | wl-copy

    # Print: select an area and annotate it; Shift+Print: the whole screen,
    # to the clipboard
    bind=NONE,Print,spawn,sixos-screenshot
    bind=SHIFT,Print,spawn_shell,grim - | wl-copy

    # volume and brightness keys
    bind=NONE,XF86AudioRaiseVolume,spawn,wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+
    bind=NONE,XF86AudioLowerVolume,spawn,wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bind=NONE,XF86AudioMute,spawn,wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    bind=NONE,XF86AudioMicMute,spawn,wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
    bind=NONE,XF86MonBrightnessUp,spawn,brightnessctl set 5%+
    bind=NONE,XF86MonBrightnessDown,spawn,brightnessctl set 5%-
  '';

  mango-config = p.runCommand "mango-config.conf" { } ''
    cat ${p.mangowc.src}/assets/config.conf > $out
    printf '\n# clipboard, screenshots, media keys (nix/desktop.nix)\nsource=/etc/mango/sixos.conf\n' >> $out
  '';

  # sw/etc/xdg: which portal implements what, and default applications
  xdg-config = p.linkFarm "sixos-xdg-config" ({
    # mango's own mango-portals.conf, plus the keyring for secrets
    "etc/xdg/xdg-desktop-portal/mango-portals.conf" = p.writeText "mango-portals.conf" ''
      [preferred]
      default=gtk
      org.freedesktop.impl.portal.ScreenCast=wlr
      org.freedesktop.impl.portal.Screenshot=wlr
      org.freedesktop.impl.portal.Inhibit=none
      org.freedesktop.impl.portal.Secret=gnome-keyring
    '';
  } // lib.optionalAttrs qutebrowser {
    "etc/xdg/mimeapps.list" = p.writeText "mimeapps.list" ''
      [Default Applications]
      x-scheme-handler/http=org.qutebrowser.qutebrowser.desktop
      x-scheme-handler/https=org.qutebrowser.qutebrowser.desktop
      text/html=org.qutebrowser.qutebrowser.desktop
      application/xhtml+xml=org.qutebrowser.qutebrowser.desktop
      application/pdf=org.qutebrowser.qutebrowser.desktop
      video/mp4=mpv.desktop
      video/webm=mpv.desktop
      video/x-matroska=mpv.desktop
      audio/mpeg=mpv.desktop
      audio/flac=mpv.desktop
      audio/ogg=mpv.desktop
    '';
  });

  # qutebrowser with spell-checking dictionaries (turn them on with
  # `:set spellcheck.languages '["en-US"]'`).  Its PDF viewer (pdf.js) and ad
  # blocker are already part of nixpkgs' qutebrowser.
  qutebrowser-pkg = p.symlinkJoin {
    name = "qutebrowser-with-dictionaries";
    paths = [ p.qutebrowser ];
    nativeBuildInputs = [ p.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/qutebrowser \
        --set-default QTWEBENGINE_DICTIONARIES_PATH ${p.linkFarm "qtwebengine-dictionaries" {
          "en-US-10-1.bdic" = p.hunspellDictsChromium.en_US;
        }}
    '';
  };

in
{
  inherit mango-config sixos-conf;

  packages = [
    xdg-config      # first: its mango-portals.conf wins over mango's own
    mango
    sixos-screenshot
  ] ++ (with p; [
    foot                    # terminal   (Alt+Return)
    rofi                    # launcher   (Alt+Space)
    mesa                    # GPU drivers
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk
    pipewire wireplumber    # sound; `wpctl status` shows the devices
    wl-clipboard            # wl-copy, wl-paste
    cliphist wl-clip-persist
    gnome-keyring gcr_4 libsecret   # passwords for programs; gcr asks for the keyring password
    grim slurp wayfreeze satty      # screenshots
    wev                     # shows key and mouse events (for writing bindings)
    dbus                    # dbus-update-activation-environment
    xdg-utils               # xdg-open
    brightnessctl
    adwaita-icon-theme hicolor-icon-theme
  ]) ++ lib.optionals qutebrowser ([ qutebrowser-pkg ] ++ (with p; [
    mpv yt-dlp              # videos: `:spawn mpv {url}`, or `;v` hint + mpv
    gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad gst_all_1.gst-plugins-ugly gst_all_1.gst-libav
    hunspell hunspellDicts.en_US    # spell checking for other programs
    nss.tools               # certutil, for importing certificates
  ]));
}
