#!/usr/bin/env python3
"""Update pins.json (and the table in README.md) to the newest upstream code.

    scripts/update-pins.py                    # newest commits on the pinned branches
    scripts/update-pins.py --release nixos-26.11   # also switch NixOS release
    scripts/update-pins.py --check-new-release     # only print a newer release branch, if any

Needs `git` and `nix-prefetch-url`.  .github/workflows/update.yml runs this
every week, runs the tests, and commits the result only if they pass.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS = os.path.join(ROOT, "pins.json")
README = os.path.join(ROOT, "README.md")


def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def ls_remote(url, pattern):
    refs = {}
    for line in sh("git", "ls-remote", url, pattern).splitlines():
        rev, ref = line.split("\t")
        refs[ref] = rev
    return refs


def branch_head(url, branch):
    refs = ls_remote(url, f"refs/heads/{branch}")
    if f"refs/heads/{branch}" not in refs:
        sys.exit(f"branch {branch} not found in {url}")
    return refs[f"refs/heads/{branch}"]


def prefetch_tarball(url):
    return sh("nix-prefetch-url", "--unpack", "--type", "sha256", url).splitlines()[-1]


def newest_release(url):
    """The newest nixos-YY.MM branch (not -small, not unstable)."""
    best = None
    for ref in ls_remote(url, "refs/heads/nixos-*"):
        m = re.fullmatch(r"refs/heads/nixos-(\d\d)\.(\d\d)", ref)
        if m:
            key = (int(m.group(1)), int(m.group(2)))
            if best is None or key > best[0]:
                best = (key, ref.removeprefix("refs/heads/"))
    return best[1] if best else None


def release_key(branch):
    m = re.fullmatch(r"nixos-(\d\d)\.(\d\d)", branch)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def sixos_base_nixpkgs(sixos_url, rev):
    """The nixpkgs tarball that upstream sixos pins in its own default.nix."""
    raw = f"{sixos_url}/raw/commit/{rev}/default.nix"
    with urllib.request.urlopen(raw, timeout=60) as r:
        text = r.read().decode()
    m = re.search(
        r"nixpkgs-path\s*\?\s*builtins\.fetchTarball\s*\{\s*"
        r'url\s*=\s*"([^"]+)";\s*sha256\s*=\s*"([^"]+)";',
        text,
    )
    if not m:
        sys.exit(f"could not find the nixpkgs-path pin in {raw}")
    return {"url": m.group(1), "sha256": m.group(2)}


def update_readme(pins):
    s, d, b = pins["sixos"], pins["nixpkgs-desktop"], pins["nixpkgs-base"]
    base_rev = re.search(r"/archive/([0-9a-f]{40})", b["url"])
    base_rev = base_rev.group(1) if base_rev else b["url"]
    table = "\n".join([
        "| what | from | pinned revision |",
        "| ---- | ---- | --------------- |",
        f"| sixos | [{s['url'].split('//')[1]}]({s['url']}) `{s['branch']}` "
        f"| [`{s['rev'][:12]}`]({s['url']}/commit/{s['rev']}) |",
        f"| kernel, firmware, ly, mango, desktop | nixpkgs `{d['branch']}` "
        f"| [`{d['rev'][:12]}`]({d['url']}/commit/{d['rev']}) |",
        f"| base system (s6, busybox, doas, nix) | nixpkgs, as pinned by sixos "
        f"| [`{base_rev[:12]}`](https://github.com/NixOS/nixpkgs/commit/{base_rev}) |",
    ])
    text = open(README).read()
    new = re.sub(r"(<!-- pins:begin -->\n).*?(\n<!-- pins:end -->)",
                 lambda m: m.group(1) + table + m.group(2), text, flags=re.S)
    if new == text and "<!-- pins:begin -->" not in text:
        sys.exit("README.md has no <!-- pins:begin --> / <!-- pins:end --> block")
    open(README, "w").write(new)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", help="switch nixpkgs-desktop to this branch, e.g. nixos-26.11")
    ap.add_argument("--check-new-release", action="store_true",
                    help="print a newer nixos-YY.MM branch than the pinned one, if there is one")
    ap.add_argument("--github-output", action="store_true",
                    help="also write results to $GITHUB_OUTPUT")
    a = ap.parse_args()

    pins = json.load(open(PINS))
    old = json.dumps(pins, sort_keys=True)
    d = pins["nixpkgs-desktop"]

    if a.check_new_release:
        newest = newest_release(d["url"])
        newer = newest if newest and release_key(newest) > release_key(d["branch"]) else ""
        print(newer)
        if a.github_output:
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"new_release={newer}\n")
        return

    changes = []

    # sixos
    s = pins["sixos"]
    rev = branch_head(s["url"], s["branch"])
    if rev != s["rev"]:
        changes.append(f"sixos: {s['rev'][:12]} -> {rev[:12]} ({s['url']}/compare/{s['rev']}...{rev})")
        s["rev"] = rev
        s["sha256"] = prefetch_tarball(f"{s['url']}/archive/{rev}.tar.gz")
        base = sixos_base_nixpkgs(s["url"], rev)
        if base != pins["nixpkgs-base"]:
            changes.append(f"base nixpkgs (as pinned by sixos): {base['url']}")
            pins["nixpkgs-base"] = base

    # nixpkgs for the kernel and desktop
    if a.release and a.release != d["branch"]:
        changes.append(f"nixpkgs-desktop: branch {d['branch']} -> {a.release}")
        d["branch"] = a.release
    rev = branch_head(d["url"], d["branch"])
    if rev != d["rev"]:
        changes.append(f"nixpkgs-desktop ({d['branch']}): {d['rev'][:12]} -> {rev[:12]} "
                       f"({d['url']}/compare/{d['rev']}...{rev})")
        d["rev"] = rev
        d["sha256"] = prefetch_tarball(f"{d['url']}/archive/{rev}.tar.gz")

    changed = json.dumps(pins, sort_keys=True) != old
    if changed:
        with open(PINS, "w") as f:
            json.dump(pins, f, indent=2)
            f.write("\n")
    update_readme(pins)

    summary = "\n".join(f"- {c}" for c in changes) or "- everything is already up to date"
    print(summary)
    if a.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"changed={'true' if changed else 'false'}\n")
            f.write(f"summary<<EOF\n{summary}\nEOF\n")


if __name__ == "__main__":
    main()
