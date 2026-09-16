#!/usr/bin/env bash
#
# publish_catalogs.sh — regenerate catalog-manifest.json from the current
# rule catalogs (fresh sha256), optionally bumping catalogVersion, then
# commit + push so the in-app updater (CatalogUpdater) picks them up.
#
# The manifest's `url` fields point at the raw files on `main`, so the
# bundled resource IS the published artifact — publishing between releases
# is just: edit CleanRules.json / AppLeftovers.json, run this, push.
#
# Usage:
#   scripts/publish_catalogs.sh [--bump clean|uninstall|both] [--dry-run] [--no-push]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLEAN="Burrow/Resources/CleanRules.json"
LEFT="Burrow/Resources/AppLeftovers.json"
MANIFEST="catalog-manifest.json"
RAW_BASE="https://raw.githubusercontent.com/guide-vinh/Burrow/main"

BUMP=""
DRY=0
PUSH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump) BUMP="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-push) PUSH=0; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

bump_version() { # $1 = json file → increments the top-level catalogVersion in place, preserving formatting
  python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()
m = re.search(r'("catalogVersion"\s*:\s*)(\d+)', s)
if not m:
    sys.exit(f"no catalogVersion in {path}")
new = int(m.group(2)) + 1
open(path, "w").write(s[:m.start()] + m.group(1) + str(new) + s[m.end():])
print(new)
PY
}

read_version() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['catalogVersion'])" "$1"; }

case "$BUMP" in
  clean)      echo "Bumped CleanRules → v$(bump_version "$CLEAN")" ;;
  uninstall)  echo "Bumped AppLeftovers → v$(bump_version "$LEFT")" ;;
  both)       echo "Bumped CleanRules → v$(bump_version "$CLEAN")"; echo "Bumped AppLeftovers → v$(bump_version "$LEFT")" ;;
  "")         : ;;
  *)          echo "Invalid --bump: $BUMP (clean|uninstall|both)" >&2; exit 2 ;;
esac

CV_CLEAN="$(read_version "$CLEAN")"; SV_CLEAN="$(python3 -c "import json;print(json.load(open('$CLEAN'))['schemaVersion'])")"
CV_LEFT="$(read_version "$LEFT")";   SV_LEFT="$(python3 -c "import json;print(json.load(open('$LEFT'))['schemaVersion'])")"
SHA_CLEAN="$(shasum -a 256 "$CLEAN" | awk '{print $1}')"
SHA_LEFT="$(shasum -a 256 "$LEFT" | awk '{print $1}')"

cat > "$MANIFEST" <<JSON
{
  "manifestVersion": 1,
  "catalogs": {
    "CleanRules": {
      "catalogVersion": ${CV_CLEAN},
      "schemaVersion": ${SV_CLEAN},
      "url": "${RAW_BASE}/${CLEAN}",
      "sha256": "${SHA_CLEAN}"
    },
    "AppLeftovers": {
      "catalogVersion": ${CV_LEFT},
      "schemaVersion": ${SV_LEFT},
      "url": "${RAW_BASE}/${LEFT}",
      "sha256": "${SHA_LEFT}"
    }
  }
}
JSON

echo "── $MANIFEST ──"
cat "$MANIFEST"

if [[ "$DRY" == "1" ]]; then
  echo "[dry-run] not committing/pushing."
  exit 0
fi

git add "$CLEAN" "$LEFT" "$MANIFEST"
if git diff --cached --quiet; then
  echo "No catalog changes to publish."
  exit 0
fi
git commit -m "chore(catalog): publish rule catalog update"
if [[ "$PUSH" == "1" ]]; then
  git push
  echo "Published. Clients will pick up the update on next launch/check."
else
  echo "Committed (not pushed — --no-push)."
fi
