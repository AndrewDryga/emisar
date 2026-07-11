#!/usr/bin/env python3
"""Fail a dependency-bump PR when a bumped package version is too fresh.

emisar is a security product: a dependency release that landed hours ago is a
supply-chain risk (a compromised maintainer account, a typosquat, a rushed
malicious minor), not harmless churn. Dependabot's `cooldown` (see
.github/dependabot.yml) suppresses *its own* too-fresh version-update PRs, but
it is PR-noise control, not enforcement — a human, another bot, or a manually
edited lockfile can still introduce a day-old release. This gate is the
enforcement layer: it runs in CI on every PR that touches a lockfile, diffs the
dependency versions against the base branch, and rejects any *added or upgraded*
version published more recently than the policy window for its bump type.

Native package-manager release-age enforcement, verified 2026-07: Hex/Mix has
no resolver-level minimum-age (`mix deps.get` takes whatever the lock pins); Go
modules have none (the proxy serves any published version regardless of age);
npm gained `.npmrc` `minimum-release-age` (npm >= 11) but emisar ships no npm
manifests, so there is nothing to configure. Only GitHub's Dependabot exposes a
`cooldown` knob, and only for the PRs it opens. That leaves CI as the one place
an age policy can actually be *enforced* across all three ecosystems — this
script.

Windows mirror the Dependabot `cooldown` config so the two layers agree; keep
them in sync when either changes. Escape hatch for an urgent security fix that
must land before its window elapses: an audited allowlist entry in
`.dep-age-allow` (see that file's header) — a committed, reviewable paper trail,
not a silent flag.

Usage:
  dep-age-gate.py check [--base <ref>]   diff vs base, query registries, enforce
  dep-age-gate.py self-test              offline fixtures (no network) for CI

Exit status: 0 = clean, 1 = a too-fresh dependency (or unverifiable age), 2 =
usage/internal error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# Age windows in days, keyed by bump type, mirroring .github/dependabot.yml
# `cooldown`. "new" = a dependency not present on the base branch; "unknown" =
# a version string we could not parse as semver. Both fall back to the
# most-conservative-that-stays-usable default (7d), matching cooldown's
# `default-days`.
WINDOWS = {"major": 30, "minor": 14, "patch": 7, "new": 7, "unknown": 7}

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ALLOWLIST = os.path.join(REPO_ROOT, ".dep-age-allow")

# (ecosystem, lockfile relative to repo root)
MANIFESTS = [
    ("hex", "portal/mix.lock"),
    ("go", "runner/go.mod"),
    ("go", "mcp/go.mod"),
]


# --------------------------------------------------------------------------- #
# Lockfile parsing: manifest text -> {package: version}
# --------------------------------------------------------------------------- #

_HEX_LINE = re.compile(r'^\s*"(?P<name>[^"]+)":\s*\{:hex,\s*:[^,]+,\s*"(?P<ver>[^"]+)"')
_GO_REQUIRE_LINE = re.compile(r"^\s*(?P<mod>[^\s()]+)\s+(?P<ver>v[^\s]+)")


def parse_hex(text: str) -> dict[str, str]:
    """mix.lock -> {package: version}, hex packages only.

    :git / :path entries have no registry release date to check; the
    deps-audit skill already flags them as un-audited-by-hex, so we skip them
    here rather than fail (they can't be aged, not that they're safe)."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        m = _HEX_LINE.match(line)
        if m:
            out[m.group("name")] = m.group("ver")
    return out


def parse_go(text: str) -> dict[str, str]:
    """go.mod -> {module: version} across every require entry (direct and
    // indirect). replace / exclude / retract directives are ignored — replace
    targets are pinned locally and carry no proxy release date."""
    out: dict[str, str] = {}
    in_block = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("require ("):
            in_block = True
            continue
        if in_block:
            if line == ")":
                in_block = False
                continue
            m = _GO_REQUIRE_LINE.match(line)
            if m:
                out[m.group("mod")] = m.group("ver")
            continue
        if line.startswith("require "):
            m = _GO_REQUIRE_LINE.match(line[len("require ") :])
            if m:
                out[m.group("mod")] = m.group("ver")
    return out


PARSERS = {"hex": parse_hex, "go": parse_go}


_HEX_NONREG_LINE = re.compile(r'^\s*"(?P<name>[^"]+)":\s*\{:(?P<kind>git|path)\b')


def parse_nonregistry(eco: str, text: str) -> dict[str, str]:
    """{name: source-descriptor} for deps with NO registry release date — hex
    :git / :path packages and go `replace` targets. These bypass age
    enforcement entirely (there is nothing to age-check), which is exactly the
    shape a malicious dependency takes to slip a lockfile gate. An added or
    changed one is FAILED for human review rather than silently trusted."""
    out: dict[str, str] = {}
    if eco == "hex":
        for line in text.splitlines():
            m = _HEX_NONREG_LINE.match(line)
            if m:
                out[m.group("name")] = f"{m.group('kind')}: {line.strip()}"
    elif eco == "go":
        in_block = False
        for raw in text.splitlines():
            line = raw.strip()
            if line.startswith("replace ("):
                in_block = True
                continue
            if in_block:
                if line == ")":
                    in_block = False
                elif "=>" in line:
                    out[line.split(None, 1)[0]] = "replace: " + line.split("=>", 1)[1].strip()
                continue
            if line.startswith("replace ") and "=>" in line:
                body = line[len("replace ") :]
                out[body.split(None, 1)[0]] = "replace: " + body.split("=>", 1)[1].strip()
    return out


# --------------------------------------------------------------------------- #
# Semver bump classification
# --------------------------------------------------------------------------- #

_SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)")


def bump_type(old: str | None, new: str) -> str:
    """Classify old->new as major/minor/patch, "new" when there was no prior
    version, or "unknown" when either side isn't parseable semver (e.g. a Go
    pseudo-version bump we can't rank — treated conservatively)."""
    if old is None:
        return "new"
    mo, mn = _SEMVER.match(old), _SEMVER.match(new)
    if not mo or not mn:
        return "unknown"
    o, n = [int(x) for x in mo.groups()], [int(x) for x in mn.groups()]
    if n[0] != o[0]:
        return "major"
    if n[1] != o[1]:
        return "minor"
    return "patch"


# --------------------------------------------------------------------------- #
# Registry lookups: (ecosystem, package, version) -> published_at (UTC)
# --------------------------------------------------------------------------- #


def _get_json(url: str, attempts: int = 3) -> dict:
    last: Exception | None = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "emisar-dep-age-gate"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                return json.load(resp)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last = exc
    raise RuntimeError(f"could not fetch {url} after {attempts} attempts: {last}")


def _go_escape(path: str) -> str:
    """Go module proxy case-encoding: every uppercase letter -> '!'+lowercase."""
    return re.sub(r"[A-Z]", lambda m: "!" + m.group(0).lower(), path)


def published_at(eco: str, package: str, version: str) -> datetime:
    """Registry publish timestamp for a package version, as an aware UTC
    datetime. Raises on an unverifiable version (the caller fails closed)."""
    if eco == "hex":
        data = _get_json(f"https://hex.pm/api/packages/{package}/releases/{version}")
        ts = data["inserted_at"]
    elif eco == "go":
        data = _get_json(f"https://proxy.golang.org/{_go_escape(package)}/@v/{version}.info")
        ts = data["Time"]
    else:
        raise ValueError(f"unknown ecosystem {eco!r}")
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)


# --------------------------------------------------------------------------- #
# Allowlist (urgent-security-fix escape hatch)
# --------------------------------------------------------------------------- #


def load_allowlist() -> set[tuple[str, str, str]]:
    """Parse .dep-age-allow -> {(ecosystem, package, version)}. A line must
    carry a non-empty reason after the version or it is rejected — the whole
    point is an auditable justification, so a bare exemption is a hard error."""
    allowed: set[tuple[str, str, str]] = set()
    if not os.path.exists(ALLOWLIST):
        return allowed
    with open(ALLOWLIST, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 3)
            if len(parts) < 4 or not parts[3].strip():
                die(f".dep-age-allow:{n}: expected `ecosystem package version reason`, got: {raw.strip()!r}")
            allowed.add((parts[0], parts[1], parts[2]))
    return allowed


# --------------------------------------------------------------------------- #
# Policy engine (pure — the self-test drives this without a network)
# --------------------------------------------------------------------------- #


def evaluate(candidates, ages, allowed, now):
    """candidates: [(eco, package, old_ver_or_None, new_ver)]
    ages:       {(eco, package, new_ver): published_at datetime}
    allowed:    {(eco, package, new_ver)} exempted by the allowlist
    now:        aware UTC datetime
    -> list of violation dicts (empty == clean)."""
    violations = []
    for eco, pkg, old, new in candidates:
        key = (eco, pkg, new)
        if key in allowed:
            continue
        kind = bump_type(old, new)
        window = WINDOWS[kind]
        pub = ages[key]
        age_days = (now - pub).total_seconds() / 86400.0
        if age_days < window:
            violations.append(
                {
                    "ecosystem": eco,
                    "package": pkg,
                    "version": new,
                    "bump": kind,
                    "published_at": pub.isoformat(),
                    "age_days": round(age_days, 1),
                    "window_days": window,
                }
            )
    return violations


# --------------------------------------------------------------------------- #
# check subcommand
# --------------------------------------------------------------------------- #


def git_show(ref: str, path: str) -> str | None:
    """Contents of `path` at `ref`, or None when the file is absent there
    (a brand-new lockfile: every entry is treated as newly added)."""
    r = subprocess.run(
        ["git", "-C", REPO_ROOT, "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
    )
    return r.stdout if r.returncode == 0 else None


def collect_candidates(base_ref: str):
    """Diff every manifest against base_ref -> the added/upgraded versions to
    age-check: [(eco, package, old_or_None, new)]."""
    candidates = []
    for eco, path in MANIFESTS:
        head_text = None
        full = os.path.join(REPO_ROOT, path)
        if os.path.exists(full):
            with open(full, encoding="utf-8") as fh:
                head_text = fh.read()
        if head_text is None:
            continue
        head = PARSERS[eco](head_text)
        base_text = git_show(base_ref, path)
        base = PARSERS[eco](base_text) if base_text else {}
        for pkg, new in head.items():
            old = base.get(pkg)
            if old != new:  # added (old is None) or version changed
                candidates.append((eco, pkg, old, new))
    return candidates


def collect_nonregistry_changes(base_ref: str):
    """Added or changed non-registry sources vs base_ref -> [(eco, name, src)].
    A hex :git/:path or a go replace that is new (or whose target changed) can't
    be age-verified, so it is surfaced for review."""
    changes = []
    for eco, path in MANIFESTS:
        full = os.path.join(REPO_ROOT, path)
        if not os.path.exists(full):
            continue
        with open(full, encoding="utf-8") as fh:
            head = parse_nonregistry(eco, fh.read())
        base_text = git_show(base_ref, path)
        base = parse_nonregistry(eco, base_text) if base_text else {}
        for name, src in head.items():
            if base.get(name) != src:
                changes.append((eco, name, src))
    return changes


def ref_exists(ref: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", REPO_ROOT, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
            capture_output=True,
        ).returncode
        == 0
    )


def run_check(base_ref: str) -> int:
    if not ref_exists(base_ref):
        # No resolvable base (e.g. a zero SHA on an initial/force push) means we
        # can't tell which versions this change *introduced*. Treating every
        # existing dep as newly added would flag deps that already merged through
        # the PR gate, so skip instead — the PR path is the real enforcement point.
        print(f"dep-age-gate: base ref {base_ref!r} does not resolve; nothing to diff, skipping.")
        return 0

    allowed = load_allowlist()

    # A non-registry source (hex :git/:path, go replace) has no release date to
    # age-check, so it would sail through the age gate — the exact bypass a
    # malicious dep uses. Fail on any added/changed one unless it's audited in
    # the allowlist under the `nonregistry` keyword.
    nonreg = [c for c in collect_nonregistry_changes(base_ref) if (c[0], c[1], "nonregistry") not in allowed]
    if nonreg:
        print("::error::dep-age-gate: added/changed non-registry dependency source(s) — cannot age-verify, needs review:")
        for eco, name, src in nonreg:
            print(f"  - {eco} {name}: {src}")
        print(
            "\nA :git/:path (hex) or replace (go) dependency bypasses release-age enforcement. "
            "Vet it (/deps-audit), then add `<eco> <name> nonregistry <reason>` to .dep-age-allow."
        )
        return 1

    candidates = collect_candidates(base_ref)
    if not candidates:
        print(f"dep-age-gate: no dependency version changes vs {base_ref}.")
        return 0

    print(f"dep-age-gate: checking {len(candidates)} changed dependency version(s) vs {base_ref}…")

    ages = {}
    for eco, pkg, _old, new in candidates:
        key = (eco, pkg, new)
        if key in allowed or key in ages:
            continue
        try:
            ages[key] = published_at(eco, pkg, new)
        except Exception as exc:  # fail closed: an unverifiable age blocks the PR
            print(f"::error::dep-age-gate: cannot verify release age for {eco} {pkg} {new}: {exc}")
            return 1

    now = datetime.now(timezone.utc)
    violations = evaluate(candidates, ages, allowed, now)

    if not violations:
        skipped = sum(1 for c in candidates if (c[0], c[1], c[3]) in allowed)
        note = f" ({skipped} allow-listed)" if skipped else ""
        print(f"dep-age-gate: all changed dependencies are past their release-age window{note}.")
        return 0

    print("::error::dep-age-gate: dependency bump(s) are too fresh (supply-chain risk):")
    for v in sorted(violations, key=lambda x: x["age_days"]):
        print(
            f"  - {v['ecosystem']} {v['package']} {v['version']} ({v['bump']}): "
            f"published {v['published_at']}, {v['age_days']}d old, needs >= {v['window_days']}d"
        )
    print(
        "\nWait until each version clears its window (windows mirror .github/dependabot.yml cooldown). "
        "For an urgent security fix that must land sooner, add an audited entry to .dep-age-allow."
    )
    return 1


# --------------------------------------------------------------------------- #
# self-test subcommand (offline; the reject/allow evidence CI runs every time)
# --------------------------------------------------------------------------- #


def run_self_test() -> int:
    now = datetime(2026, 7, 10, tzinfo=timezone.utc)

    def days_ago(d):
        return datetime.fromtimestamp(now.timestamp() - d * 86400, tz=timezone.utc)

    # Parser fixtures.
    hex_lock = '  "plug": {:hex, :plug, "1.18.0", "hash", [:mix], [], "hexpm", "h"},\n' \
               '  "some_git": {:git, "https://x", "ref", []},\n'
    assert parse_hex(hex_lock) == {"plug": "1.18.0"}, "hex parser / git skip"
    go_mod = "module x\n\ngo 1.26\n\nrequire (\n\tgithub.com/coder/websocket v1.8.14\n" \
             "\tgithub.com/spf13/pflag v1.0.10 // indirect\n)\n\nrequire example.com/single v2.0.0\n"
    assert parse_go(go_mod) == {
        "github.com/coder/websocket": "v1.8.14",
        "github.com/spf13/pflag": "v1.0.10",
        "example.com/single": "v2.0.0",
    }, "go parser (block + single-line + indirect)"

    # Non-registry source detection — these have no release date and must be
    # surfaced, not silently skipped like the registry parsers do.
    hex_nonreg = parse_nonregistry(
        "hex",
        '  "some_git": {:git, "https://x", "ref", []},\n'
        '  "plug": {:hex, :plug, "1.0.0", "h", [:mix], [], "hexpm", "h"},\n',
    )
    assert set(hex_nonreg) == {"some_git"} and hex_nonreg["some_git"].startswith("git:"), "hex nonreg detect"
    assert parse_nonregistry("go", "replace example.com/x => ./local\n") == {
        "example.com/x": "replace: ./local"
    }, "go single replace"
    assert parse_nonregistry("go", "replace (\n\texample.com/y => ../y v1.0.0\n)\n") == {
        "example.com/y": "replace: ../y v1.0.0"
    }, "go block replace"

    # Bump classification.
    assert bump_type(None, "1.0.0") == "new"
    assert bump_type("1.2.3", "2.0.0") == "major"
    assert bump_type("1.2.3", "1.3.0") == "minor"
    assert bump_type("1.2.3", "1.2.4") == "patch"
    assert bump_type("1.2", "1.3") == "unknown"  # not full semver -> conservative
    assert _go_escape("github.com/Azure/go-x") == "github.com/!azure/go-x"

    # Policy: a too-fresh patch is rejected; an old-enough one is allowed.
    candidates = [
        ("hex", "fresh_patch", "1.2.3", "1.2.4"),   # 2d old, patch window 7 -> REJECT
        ("hex", "aged_patch", "1.2.3", "1.2.4"),    # 30d old, patch window 7 -> allow
        ("go", "github.com/x/major", "v1.0.0", "v2.0.0"),  # 20d old, major window 30 -> REJECT
    ]
    ages = {
        ("hex", "fresh_patch", "1.2.4"): days_ago(2),
        ("hex", "aged_patch", "1.2.4"): days_ago(30),
        ("go", "github.com/x/major", "v2.0.0"): days_ago(20),
    }
    v = evaluate(candidates, ages, allowed=set(), now=now)
    got = {x["package"] for x in v}
    assert got == {"fresh_patch", "github.com/x/major"}, f"rejected set wrong: {got}"

    # The allowlist exempts the urgent fix.
    v2 = evaluate(candidates, ages, allowed={("hex", "fresh_patch", "1.2.4")}, now=now)
    assert {x["package"] for x in v2} == {"github.com/x/major"}, "allowlist did not exempt"

    print("dep-age-gate self-test: PASS")
    print("  rejected too-fresh: hex fresh_patch 1.2.4 (2d < 7d), go .../major v2.0.0 (20d < 30d)")
    print("  allowed old-enough: hex aged_patch 1.2.4 (30d >= 7d)")
    print("  allowlist exempts:  hex fresh_patch 1.2.4 when listed in .dep-age-allow")
    print("  non-registry flag:  hex :git/:path + go replace surfaced for review")
    return 0


def die(msg: str):
    print(f"::error::dep-age-gate: {msg}", file=sys.stderr)
    sys.exit(2)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="diff vs base ref, query registries, enforce")
    c.add_argument("--base", default=os.environ.get("DEP_AGE_BASE_REF", "origin/main"))
    sub.add_parser("self-test", help="offline fixtures (no network)")
    args = p.parse_args(argv)

    if args.cmd == "self-test":
        return run_self_test()
    return run_check(args.base)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
