#!/usr/bin/env python3
"""
sync_mole.py — diff upstream tw93/Mole cleanup paths against Burrow's curated
JSON catalogs, as a REVIEW AID. It never writes the catalogs.

Mole encodes paths in bash arrays across lib/clean/*.sh and lib/uninstall/*.sh,
with no titles/groups/icons/risk/bundle-ids. Burrow's JSON is hand-curated with
that metadata. So this tool only surfaces which upstream paths are NEW (candidates
to add) or Burrow-only, grouped by source file — a human/Claude does the merge.

Zero dependencies (urllib only). The Mole commit is pinned in scripts/mole.lock.

Usage:
  scripts/sync_mole.py                 # fetch pinned Mole, print the diff report
  scripts/sync_mole.py --stubs         # also print pasteable JSON rule stubs for NEW paths
  scripts/sync_mole.py --sha <SHA>     # override the pinned commit
  scripts/sync_mole.py --self-test     # offline unit checks for the extractor
"""
import argparse
import json
import os
import re
import sys
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(REPO_ROOT, "scripts", "mole.lock")
CLEAN_JSON = os.path.join(REPO_ROOT, "Burrow", "Resources", "CleanRules.json")
LEFTOVERS_JSON = os.path.join(REPO_ROOT, "Burrow", "Resources", "AppLeftovers.json")

CLEAN_FILES = ["app_caches.sh", "apps.sh", "brew.sh", "caches.sh", "dev.sh",
               "hints.sh", "project.sh", "purge_shared.sh", "system.sh", "user.sh"]
UNINSTALL_FILES = ["batch.sh", "brew.sh", "steam.sh"]

# Quoted string literal (double or single quotes).
QUOTED = re.compile(r'"([^"]*)"' + r"|'([^']*)'")
# A token looks like a path if it starts at one of these roots or contains a
# recognizable macOS cache/support segment.
PATH_START = re.compile(r'^(~|\$\{?HOME\}?|/Library|/Users|/private|/var|/tmp|/Applications|/System|/opt|/usr/local)')
PATH_SEGMENT = re.compile(r'/(Caches|Application Support|Logs|Preferences|Containers|Saved Application State|WebKit|HTTPStorages)/')


def read_lock_sha():
    try:
        with open(LOCK) as f:
            for line in f:
                if line.strip().startswith("sha="):
                    return line.strip().split("=", 1)[1]
    except FileNotFoundError:
        pass
    return "main"


def fetch(sha, subdir, name):
    url = f"https://raw.githubusercontent.com/tw93/Mole/{sha}/lib/{subdir}/{name}"
    with urllib.request.urlopen(url, timeout=15) as r:  # noqa: S310 (trusted host)
        return r.read().decode("utf-8", errors="replace")


def normalize(token):
    """Canonicalize a path-ish token for comparison. Returns None if it's not
    path-like."""
    t = token.strip()
    if not t:
        return None
    # Collapse HOME variable forms to '~'.
    t = re.sub(r'^\$\{?HOME\}?', '~', t)
    t = t.rstrip("/")
    t = re.sub(r'/{2,}', '/', t)
    if not (PATH_START.match(t) or PATH_SEGMENT.search(t)):
        return None
    return t


def confidence(token):
    """'low' when the token still looks shell-y (likely a fragment, not a real
    path) so the report can flag it rather than assert it."""
    if "$" in token or "`" in token or "*" in token.split("/")[0]:
        return "low"
    if " " in token and "/" not in token:
        return "low"
    return "ok"


def extract_paths(text):
    """Return {normalized_path: confidence} from bash source text."""
    out = {}
    for m in QUOTED.finditer(text):
        raw = m.group(1) if m.group(1) is not None else m.group(2)
        norm = normalize(raw)
        if norm is None:
            continue
        conf = confidence(norm)
        # Keep the best confidence seen for a path.
        if norm not in out or conf == "ok":
            out[norm] = conf
    return out


def burrow_clean_paths():
    with open(CLEAN_JSON) as f:
        cat = json.load(f)
    paths = set()
    for c in cat.get("categories", []):
        for rule in c.get("rules", []):
            p = rule.get("path")
            if p:
                n = normalize(p)
                paths.add(n if n else p.rstrip("/"))
    return paths


def burrow_leftover_paths():
    with open(LEFTOVERS_JSON) as f:
        cat = json.load(f)
    paths = set()
    for key in ("userPaths", "systemPaths"):
        for p in cat.get(key, []):
            if p.get("path"):
                paths.add(p["path"].rstrip("/"))
    for vo in cat.get("vendorOverrides", {}).values():
        if isinstance(vo, dict):
            for p in vo.get("paths", []):
                if p.get("path"):
                    paths.add(p["path"].rstrip("/"))
    return paths


def report(title, files_paths, burrow_paths, stubs):
    print(f"\n{'=' * 70}\n{title}\n{'=' * 70}")
    total_new = 0
    for fname, found in files_paths.items():
        new = {p: c for p, c in found.items() if p not in burrow_paths}
        if not new:
            continue
        total_new += len(new)
        print(f"\n── {fname}: {len(new)} NEW path(s) not in Burrow ──")
        for p in sorted(new):
            flag = "  [low-confidence]" if new[p] == "low" else ""
            print(f"  + {p}{flag}")
        if stubs:
            print("  stubs:")
            for p in sorted(new):
                kind = "glob" if "*" in p else "directoryContents"
                print(f'    {{ "kind": "{kind}", "path": "{p}" }},')
    print(f"\n{title}: {total_new} new upstream path(s) to review.")
    # Burrow-only (paths we have that Mole no longer lists) — informational.
    all_mole = set().union(*[set(f.keys()) for f in files_paths.values()]) if files_paths else set()
    burrow_only = sorted(burrow_paths - all_mole)
    print(f"{title}: {len(burrow_only)} Burrow path(s) not seen in this Mole snapshot "
          f"(Burrow-specific or dropped upstream).")


def run(sha, stubs):
    print(f"Syncing against tw93/Mole @ {sha}")
    clean_files = {}
    for name in CLEAN_FILES:
        try:
            clean_files[name] = extract_paths(fetch(sha, "clean", name))
        except Exception as e:  # noqa: BLE001
            print(f"  ! skip clean/{name}: {e}", file=sys.stderr)
    report("CLEAN catalog (lib/clean → CleanRules.json)", clean_files, burrow_clean_paths(), stubs)

    un_files = {}
    for name in UNINSTALL_FILES:
        try:
            un_files[name] = extract_paths(fetch(sha, "uninstall", name))
        except Exception as e:  # noqa: BLE001
            print(f"  ! skip uninstall/{name}: {e}", file=sys.stderr)
    print("\nNOTE: AppLeftovers uses {bundleId}/{name} placeholders while Mole uses")
    print("literal paths, so uninstall diffs are inherently noisy — treat as hints.")
    report("UNINSTALL catalog (lib/uninstall → AppLeftovers.json)", un_files, burrow_leftover_paths(), stubs)


def self_test():
    sample = '''
    readonly TARGETS=(
        "$HOME/Library/Caches/Google/Chrome"
        "${HOME}/Library/Application Support/Foo//"
        "~/Library/Logs/Bar"
        "/Library/Caches/Baz"
        "node_modules"            # not a path
        "echo hello"              # not a path
        "$SOME_VAR/Library/Caches/X"
    )
    '''
    paths = extract_paths(sample)
    assert "~/Library/Caches/Google/Chrome" in paths, paths
    assert "~/Library/Application Support/Foo" in paths, "HOME + trailing slash normalize"
    assert "~/Library/Logs/Bar" in paths
    assert "/Library/Caches/Baz" in paths
    assert "node_modules" not in paths, "bare word rejected"
    assert not any(p.endswith("hello") for p in paths), "non-path rejected"
    # $SOME_VAR path is kept (has a cache segment) but flagged low-confidence.
    lows = [p for p, c in paths.items() if c == "low"]
    assert any("SOME_VAR" in p or "$" in p for p in lows) or lows, f"expected a low-confidence token: {paths}"
    assert normalize("not/a/path") is None
    assert normalize("") is None
    print("self-test OK:", len(paths), "paths extracted")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", default=None, help="override pinned Mole commit")
    ap.add_argument("--stubs", action="store_true", help="print JSON rule stubs for new paths")
    ap.add_argument("--self-test", action="store_true", help="run offline extractor checks")
    args = ap.parse_args()

    if args.self_test:
        self_test()
        return

    run(args.sha or read_lock_sha(), args.stubs)


if __name__ == "__main__":
    main()
