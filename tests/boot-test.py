"""Boot an installed sixos disk in QEMU and check it over the serial console.

Called by tests/default.nix; see the comment there for what is checked.
Everything the VM prints on its serial port is copied to stdout (and so to
the Nix build log) and to $out/serial.log.
"""

import argparse
import os
import re
import shlex
import socket
import subprocess
import sys
import threading
import time

p = argparse.ArgumentParser()
p.add_argument("--qemu", required=True)
p.add_argument("--ovmf", required=True)
p.add_argument("--disk", required=True)
p.add_argument("--out", required=True)
p.add_argument("--user", required=True)
p.add_argument("--uid", required=True)
p.add_argument("--root-password", required=True)
p.add_argument("--user-password", required=True)
args = p.parse_args()

KVM = os.access("/dev/kvm", os.R_OK | os.W_OK)
# without KVM everything is ~10x slower
SLOW = 1 if KVM else 8

monitor_path = os.path.abspath("monitor.sock")
cmd = [
    args.qemu,
    "-machine", "q35",
    "-m", "3072",
    "-smp", "2",
    "-bios", args.ovmf,
    "-drive", f"file={args.disk},if=none,id=root,format=qcow2",
    "-device", "nvme,serial=sixostest,drive=root",
    "-device", "virtio-vga",
    "-display", "none",
    # a network card, for NetworkManager's DHCP.  (QEMU's DHCP hands out a
    # gateway and a DNS server; the Nix build sandbox has no network, so
    # nothing goes anywhere.)
    "-nic", "user,model=virtio-net-pci",
    "-serial", "stdio",
    "-monitor", f"unix:{monitor_path},server=on,wait=off",
] + (["-enable-kvm", "-cpu", "host"] if KVM else [])

print("+ " + " ".join(cmd), flush=True)
log = open(os.path.join(args.out, "serial.log"), "wb")
qemu = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)

buf = bytearray()
pos = 0               # everything before this has been matched already
lock = threading.Lock()


def reader():
    while True:
        chunk = qemu.stdout.read1(4096)
        if not chunk:
            return
        with lock:
            buf.extend(chunk)
        log.write(chunk)
        log.flush()
        sys.stdout.buffer.write(chunk)
        sys.stdout.flush()


threading.Thread(target=reader, daemon=True).start()

failures = []


def soft_fail(msg):
    """Record a failure but keep going, so one run reports every problem."""
    print(f"\n\n### FAILED (continuing): {msg}\n", flush=True)
    failures.append(msg)


def fail(msg):
    print(f"\n\n### TEST FAILED: {msg}\n", flush=True)
    finish(1)


def finish(code):
    try:
        screenshot("final")
    except Exception:
        pass
    if qemu.poll() is None:
        qemu.kill()
    with open(os.path.join(args.out, "result.txt"), "w") as f:
        f.write("PASS\n" if code == 0 else "FAIL\n")
    sys.exit(code)


def expect(pattern, timeout, what=None):
    """Wait until `pattern` (a regex) appears in output after the last match."""
    global pos
    rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern, re.S)
    deadline = time.time() + timeout * SLOW
    while time.time() < deadline:
        with lock:
            m = rx.search(buf, pos)
            if m:
                pos = m.end()
                return m
        if qemu.poll() is not None:
            fail(f"QEMU exited while waiting for {what or pattern!r}")
        time.sleep(0.2)
    fail(f"timed out after {timeout * SLOW}s waiting for {what or pattern!r}")


def send(text):
    qemu.stdin.write(text.encode())
    qemu.stdin.flush()


counter = 0


def run(command, timeout=60):
    """Run a shell command on the serial console; return (exit code, output)."""
    global counter, pos
    counter += 1
    tag = f"T{counter}"
    # The terminal echoes what we type; the quotes make sure the echoed
    # command line can never match the pattern below, only real output can.
    send(f"echo '<{tag}>'; {command}; echo \"</{tag} $?>\"\n")
    # (kernel messages on the same console may be mixed into the output)
    m = expect(rf"<{tag}>(.*?)</{tag} (\d+)>", timeout, f"output of {command!r}")
    return int(m.group(2)), m.group(1).decode(errors="replace")


def check(command, what, timeout=60, soft=False):
    code, out = run(command, timeout)
    if code != 0:
        (soft_fail if soft else fail)(f"{what}: `{command}` exited with {code}:\n{out}")
        return out
    print(f"\n### ok: {what}", flush=True)
    return out


def wait_until(command, what, timeout, soft=False):
    deadline = time.time() + timeout * SLOW
    while True:
        code, out = run(command)
        if code == 0:
            print(f"\n### ok: {what}", flush=True)
            return out
        if time.time() > deadline:
            (soft_fail if soft else fail)(f"{what}: `{command}` still failing after {timeout * SLOW}s:\n{out}")
            return out
        time.sleep(3)


def login(user, password, wait_for_prompt=True):
    if wait_for_prompt:
        expect(r"login: ", 60, "login prompt")
    send(user + "\n")
    expect(r"[Pp]assword: ", 30, "password prompt")
    time.sleep(0.5)
    send(password + "\n")
    # make prompts and terminal handling predictable
    run("export PS1='$ ' TERM=dumb", 30)


def logout():
    send("exit\n")


DIAGNOSTICS = [
    "ls -l /etc/pam.d/ /etc/pam.d/ /run/six/bin/doas /etc/shadow /etc/doas.conf",
    "cat /etc/pam.d/doas /etc/doas.conf",
    "cut -d: -f1,3- /etc/shadow; grep -c '[$]6[$]' /etc/shadow",
    "ls /var/log/",
    "tail -n 40 /var/log/syslog/current 2>/dev/null || true",
    "tail -n 20 /var/log/messages 2>/dev/null || true",
    "dmesg | tail -n 20",
    "tail -n 30 /var/log/networkmanager/current 2>/dev/null || true",
    "tail -n 10 /var/log/dbus/current 2>/dev/null || true",
]


def diagnose_as_root():
    """Log in as root on the serial console and print useful state."""
    logout()
    login("root", args.root_password)
    for c in DIAGNOSTICS:
        run(c, 30)


def monitor(command):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(monitor_path)
    s.settimeout(10)
    s.recv(4096)  # banner
    s.sendall(command.encode() + b"\n")
    time.sleep(0.5)
    try:
        s.recv(65536)
    except socket.timeout:
        pass
    s.close()


QEMU_KEYS = {" ": "spc", "-": "minus", ".": "dot", "_": "shift-minus", "\n": "ret", "\t": "tab"}


def type_keys(text):
    for ch in text:
        if ch.isupper():
            key = "shift-" + ch.lower()
        else:
            key = QEMU_KEYS.get(ch, ch)
        monitor(f"sendkey {key}")
        time.sleep(0.05)


def screenshot(name):
    monitor(f"screendump {os.path.join(args.out, name + '.png')} -f png")


###########################################################################
# 1. Boot to the serial `login:` prompt
###########################################################################

expect(r"Linux version", 300, "the kernel to start (GRUB worked)")
print("\n### ok: GRUB loaded the kernel", flush=True)
expect(r"login: ", 300, "the login prompt on the serial console")
print("\n### ok: booted to a login prompt", flush=True)
# On the first boot the prompt appears before sixos has created /etc/passwd,
# so wait for the services (their progress is logged to the console).
expect(r"service ly successfully started", 300, "the services to start")
print("\n### ok: all services started", flush=True)
time.sleep(2)

###########################################################################
# 2. Root: password login, then wait until every service is up
###########################################################################

login("root", args.root_password, wait_for_prompt=False)
check("test \"$(id -u)\" = 0", "root logged in with the root password")

for svc in ["seatd", "run-user", "pam-helpers", "ly", "earlyoom", "etc-ssl", "nix-daemon",
            "dbus", "wpa-supplicant", "networkmanager", "backlight", "keyring-wrapper"]:
    wait_until(f"s6-rc -a list | grep -qx '{svc}'", f"service {svc} is up", 120)
wait_until("pidof ly", "ly is running", 60)

check("test \"$(stat -c %a /etc/shadow)\" = 600", "/etc/shadow is only readable by root")
check(f"grep -q '^{args.user}:x:' /etc/passwd", "/etc/passwd points at /etc/shadow")
check("test ! -e /run/current-system/etc/shadow", "no password hashes in the Nix store")
check(f"test \"$(stat -c %u /run/user/{args.uid})\" = {args.uid}", "/run/user/<uid> exists")
check("grep -qx 'permit :wheel' /etc/doas.conf", "doas.conf requires a password")
check(f"test \"$(stat -c %U /home/{args.user}/sixos-laptop/pins.json)\" = {args.user}",
      "the repository was copied to the user's home")
check(f"test ! -e /home/{args.user}/sixos-laptop/result && test ! -L /home/{args.user}/sixos-laptop/result",
      "the repository copy has no result links")
check("grep -q ssh-ed25519 /root/.ssh/authorized_keys", "the --ssh-key was installed")
check("ls /run/booted-system/firmware/lib/firmware/iwlwifi-*.zst | head -n 1 | grep -q zst",
      "the firmware is zstd-compressed")
# networking: NetworkManager on the D-Bus system bus
code, _ = run("(for i in $(seq 120); do nmcli -t -f TYPE,STATE device | grep -q '^ethernet:connected' && exit 0; sleep 1; done; exit 1)", 150)
if code == 0:
    print("\n### ok: NetworkManager configured the network card by DHCP", flush=True)
else:
    soft_fail("NetworkManager did not configure the network card by DHCP")
    for c in ["nmcli device", "nmcli general", "ip -br link; ip -br addr", "lsmod | grep -i virtio",
              "ls /sys/class/net", "tail -n 60 /var/log/networkmanager/current",
              "tail -n 20 /var/log/wpa-supplicant/current", "tail -n 20 /var/log/dbus/current"]:
        run(c, 30)
out = check("grep -q '^nameserver 10.0.2.3' /etc/resolv.conf", "NetworkManager wrote /etc/resolv.conf", soft=True)
if failures and "resolv.conf" in failures[-1]:
    for c in ["ls -la /etc/resolv.conf /run/NetworkManager/; cat /run/NetworkManager/resolv.conf",
              "nmcli device show eth0 | grep -i -E 'dns|ip4'", "NetworkManager --print-config 2>&1 | head -40",
              "grep -i -E 'dns|resolv' /var/log/syslog/current | tail -n 20",
              "tail -n 20 /var/log/networkmanager/current"]:
        run(c, 30)
check("nmcli -t -f NAME connection show | grep -qx TestNet && nmcli -t -f NAME connection show | grep -qx OldNet",
      "NetworkManager has the installer's and the converted iwd Wi-Fi networks", soft=True)
check(f"test \"$(cat /home/{args.user}/keep-me)\" = kept", "the reinstall kept /home", soft=True)
check("for c in nmtui nmcli vim nano git curl w3m ssh lsblk parted htop sixos-rebuild; do command -v $c >/dev/null || exit 1; done",
      "the rescue tools are installed", soft=True)
check("sixos-rebuild --help | grep -q switch", "sixos-rebuild runs", soft=True)
check("grep -qx 'source=/etc/mango/sixos.conf' /etc/mango/config.conf", "mango's config includes sixos.conf", soft=True)
check("grep -q 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt && grep -q 'BEGIN CERTIFICATE' /etc/ssl/cert.pem",
      "/etc/ssl has the https certificates")
check("tr '\\0' ' ' < /proc/$(pidof nix-daemon | cut -d' ' -f1)/cmdline | grep -q 'ssl-cert-file /run/current-system/etc/ssl/certs/ca-certificates.crt'",
      "the nix-daemon knows where the certificates are")
# a system installed before /etc/ssl existed gets it from the etc-ssl target
run("rm /etc/ssl && s6-rc -d change etc-ssl && s6-rc -u change etc-ssl", 30)
check("test \"$(readlink /etc/ssl)\" = /run/current-system/etc/ssl",
      "the etc-ssl target creates a missing /etc/ssl")
for c in DIAGNOSTICS:     # recorded in the log, useful when a later step fails
    run(c, 30)
logout()

###########################################################################
# 3. The user: password login, doas asks for a password
###########################################################################

login(args.user, args.user_password)
check("test \"$(id -un)\" = " + args.user, "user logged in with their password")
check("nmcli -t general permissions | grep -q '^org.freedesktop.NetworkManager.network-control:yes$'",
      "the user may change the network (nmtui) without doas", soft=True)
check("test \"$SSL_CERT_FILE\" = /run/current-system/etc/ssl/certs/ca-certificates.crt && test \"$NIX_SSL_CERT_FILE\" = \"$SSL_CERT_FILE\"",
      "the login shell has SSL_CERT_FILE and NIX_SSL_CERT_FILE")
# what `nix-build -A hosts.laptop.configuration` relies on: the user builds
# through the nix-daemon (the store belongs to root)
check("nix-build --no-out-link --option substitute false -E 'derivation { name = \"t\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ \"-c\" \"echo ok > $out\" ]; }' | grep -q '^/nix/store/.*-t$'",
      "the user can nix-build (through the nix-daemon)", 180)
code, out = run("doas -n true")
if code == 0:
    fail("doas ran without asking for a password")
print("\n### ok: doas without a password is refused", flush=True)

# right password
send("doas id -u; echo \"<doas $?>\"\n")
expect(r"[Pp]assword:", 30, "doas password prompt")
time.sleep(0.5)
send(args.user_password + "\n")
m = expect(r"<doas (\d+)>", 30, "doas to finish")
if m.group(1) != b"0":
    soft_fail("doas rejected the user's correct password")
else:
    print("\n### ok: doas accepts the user's password", flush=True)

# wrong password
send("doas true; echo \"<doaswrong $?>\"\n")
expect(r"[Pp]assword:", 30, "doas password prompt")
time.sleep(0.5)
send("wrong-password\n")
m = expect(r"<doaswrong (\d+)>", 30, "doas to reject a wrong password")
if m.group(1) == b"0":
    fail("doas accepted a wrong password")
print("\n### ok: doas rejects a wrong password", flush=True)
logout()
login("root", args.root_password)

###########################################################################
# 4. Log in through ly and start mango
###########################################################################

time.sleep(3 * SLOW)   # let ly draw its screen
screenshot("ly")
# ly preselects the user (default-user) and starts in the password field
check(f"grep -qx '{args.user}:0' /etc/ly/save.txt", "ly preselects the user")
type_keys(args.user_password + "\n")

code, out = run("(for i in $(seq 90); do pidof mango && exit 0; sleep 1; done; exit 1)", 120)
if code != 0:
    run("tail -n 50 /var/log/ly/current", 30)
    run(f"tail -n 40 /home/{args.user}/ly-session.log", 30)
    run("tail -n 30 /var/log/ly.log", 30)
    run("tail -n 20 /var/log/syslog/current", 30)
    screenshot("ly-after-login")
    soft_fail("logging in through ly did not start mango")
else:
    print("\n### ok: logging in through ly started mango", flush=True)
    time.sleep(5 * SLOW)
    screenshot("mango")
    check(f"test \"$(stat -c %U /proc/$(pidof mango | cut -d' ' -f1))\" = {args.user}",
          "mango runs as the user, not root")
    # mango-session: D-Bus session bus and session-commands (tests/site/hosts/testvm.nix)
    check(f"test \"$(stat -c %U /proc/$(pidof dbus-daemon | cut -d' ' -f1))\" = {args.user}",
          "the session has a D-Bus session bus")
    for prog in ["pipewire", "wireplumber", "pipewire-pulse"]:
        check(f"test \"$(stat -c %U /proc/$(pidof {prog} | cut -d' ' -f1))\" = {args.user}",
              f"sound: {prog} runs as the user", soft=True)
    check(f"for p in $(pidof sleep); do grep -q 100000 /proc/$p/cmdline && stat -c %U /proc/$p; done | grep -qx {args.user}",
          "session-commands started as the user", soft=True)
    check("pidof wl-paste && pidof wl-clip-persist", "mango ran the exec-once lines of sixos.conf (clipboard)", soft=True)

    def as_user(cmd):
        """cmd as the user, in the session's environment (taken from
        wl-paste, which mango started)"""
        return ("p=$(pidof wl-paste | cut -d' ' -f1); "
                f"doas -u {args.user} env -i $(tr '\\0' '\\n' < /proc/$p/environ | grep -E "
                "'^(DBUS_SESSION_BUS_ADDRESS|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|XDG_DATA_DIRS|XDG_CONFIG_DIRS"
                "|XDG_CURRENT_DESKTOP|NIX_XDG_DESKTOP_PORTAL_DIR|PATH|HOME)=') "
                f"sh -c {shlex.quote(cmd)}")

    check(as_user("echo sixos-clip | wl-copy && sleep 1 && cliphist list | grep -q sixos-clip"),
          "the clipboard history records what is copied", soft=True)
    check(as_user("grim /tmp/shot.png && test -s /tmp/shot.png"), "grim takes a screenshot", soft=True)
    portal_get = ("dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop "
                  "/org/freedesktop/portal/desktop org.freedesktop.DBus.Properties.Get "
                  "string:org.freedesktop.portal.{} string:version | grep -q uint32")
    check(as_user(portal_get.format("Screenshot")), "the screenshot portal works (xdg-desktop-portal-wlr)", 90, soft=True)
    check(as_user(portal_get.format("FileChooser")), "the file chooser portal works (xdg-desktop-portal-gtk)", 90, soft=True)
    check(as_user("dbus-send --session --print-reply --dest=org.freedesktop.secrets /org/freedesktop/secrets "
                  "org.freedesktop.DBus.Peer.Ping >/dev/null && pidof gnome-keyring-daemon"),
          "the keyring starts on demand", 60, soft=True)
    code, out = run(as_user("QT_QPA_PLATFORM=offscreen timeout 120 qutebrowser --version 2>/dev/null | grep -m 1 'qutebrowser v'"), 150)
    if code == 0 and "qutebrowser v" in out:
        print("\n### ok: qutebrowser runs", flush=True)
    else:
        soft_fail("qutebrowser --version did not work")
    check("tr '\\0' '\\n' < /proc/$(pidof mango | cut -d' ' -f1)/environ | grep -qx 'XDG_DATA_DIRS=/run/current-system/sw/share'",
          "the session has XDG_DATA_DIRS")
    check("tr '\\0' '\\n' < /proc/$(pidof mango | cut -d' ' -f1)/environ | grep -qx 'SSL_CERT_FILE=/run/current-system/etc/ssl/certs/ca-certificates.crt'",
          "the session has SSL_CERT_FILE")

###########################################################################
# 5. poweroff powers off (sixos upstream turned it into a reboot)
###########################################################################

send("/run/init/bin/poweroff\n")
pos_before = pos
deadline = time.time() + 180 * SLOW
while qemu.poll() is None and time.time() < deadline:
    time.sleep(0.5)
with lock:
    rebooted = b"Linux version" in buf[pos_before:]
if qemu.poll() is None or rebooted:
    fail("poweroff did not power the machine off" + (" (it rebooted)" if rebooted else ""))
print("\n### ok: poweroff powered the machine off", flush=True)

if failures:
    print("\n### SOME TESTS FAILED:\n" + "\n".join("  - " + f for f in failures), flush=True)
    with open(os.path.join(args.out, "result.txt"), "w") as f:
        f.write("FAIL\n")
    sys.exit(1)
print("\n### ALL TESTS PASSED", flush=True)
with open(os.path.join(args.out, "result.txt"), "w") as f:
    f.write("PASS\n")
sys.exit(0)
