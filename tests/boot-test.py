"""Boot an installed sixos disk in QEMU and check it over the serial console.

Called by tests/default.nix; see the comment there for what is checked.
Everything the VM prints on its serial port is copied to stdout (and so to
the Nix build log) and to $out/serial.log.
"""

import argparse
import os
import re
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
    "-nic", "none",
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


def check(command, what, timeout=60):
    code, out = run(command, timeout)
    if code != 0:
        fail(f"{what}: `{command}` exited with {code}:\n{out}")
    print(f"\n### ok: {what}", flush=True)
    return out


def wait_until(command, what, timeout):
    deadline = time.time() + timeout * SLOW
    while True:
        code, out = run(command)
        if code == 0:
            print(f"\n### ok: {what}", flush=True)
            return out
        if time.time() > deadline:
            fail(f"{what}: `{command}` still failing after {timeout * SLOW}s:\n{out}")
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

for svc in ["seatd", "run-user", "pam-helpers", "dnscache", "ly", "earlyoom"]:
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
for c in DIAGNOSTICS:     # recorded in the log, useful when a later step fails
    run(c, 30)
logout()

###########################################################################
# 3. The user: password login, doas asks for a password
###########################################################################

login(args.user, args.user_password)
check("test \"$(id -un)\" = " + args.user, "user logged in with their password")
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
    check(f"test \"$(stat -c %U /proc/$(pidof pipewire | cut -d' ' -f1))\" = {args.user}",
          "session-commands started pipewire as the user")
    check("tr '\\0' '\\n' < /proc/$(pidof mango | cut -d' ' -f1)/environ | grep -qx 'XDG_DATA_DIRS=/run/current-system/sw/share'",
          "the session has XDG_DATA_DIRS")

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
