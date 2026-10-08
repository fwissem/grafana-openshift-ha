#!/usr/bin/env bash
# check-anonymity.sh - fail if a private string appears in a file Git would publish.
#
# Read-only: this script never modifies anything.
#
# It scans every tracked file plus every untracked file that is not git-ignored
# (i.e. everything `git add -A` would stage) for:
#   1. each string of the deny-list  -> ERROR (exit 1)
#   2. IPv4 addresses                -> WARNING only (review by hand)
#
# Usage:
#   scripts/check-anonymity.sh                 # uses ./.anonymity-denylist
#   scripts/check-anonymity.sh -f <denylist>   # another deny-list file
#
# Exit codes: 0 clean, 1 deny-list hit, 2 usage / missing deny-list.

set -u

DENYLIST=".anonymity-denylist"
while [ $# -gt 0 ]; do
  case "$1" in
    -f) DENYLIST="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a Git repository." >&2; exit 2; }
cd "$ROOT" || exit 2

if [ ! -f "$DENYLIST" ]; then
  echo "ERROR: deny-list '$DENYLIST' not found." >&2
  echo "       Copy .anonymity-denylist.example to .anonymity-denylist and fill it." >&2
  exit 2
fi

# Files Git would publish (tracked + untracked-but-not-ignored), NUL-separated.
FILELIST="$(mktemp)"
trap 'rm -f "$FILELIST"' EXIT
git ls-files -z --cached --others --exclude-standard > "$FILELIST"

nfiles="$(tr -cd '\0' < "$FILELIST" | wc -c | tr -d ' ')"
hits=0
npatterns=0

while IFS= read -r pattern || [ -n "$pattern" ]; do
  # strip CR (file edited on Windows) and surrounding blanks
  pattern="$(printf '%s' "$pattern" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$pattern" in ''|'#'*) continue ;; esac
  npatterns=$((npatterns + 1))
  # -I: skip binary files; -F: fixed string; -i: case-insensitive
  out="$(xargs -0 -r grep -HnIiF -e "$pattern" -- < "$FILELIST" 2>/dev/null \
         | grep -v '^\.anonymity-denylist\.example:')"
  if [ -n "$out" ]; then
    hits=$((hits + 1))
    echo "ERROR: deny-listed string found: '$pattern'"
    printf '%s\n' "$out" | cut -c1-200 | sed 's/^/    /'
  fi
done < "$DENYLIST"

# IPv4 addresses: warning only. Loopback, wildcard and documentation ranges are allowed.
ipout="$(xargs -0 -r grep -HnIoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -- < "$FILELIST" 2>/dev/null \
        | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$')"
if [ -n "$ipout" ]; then
  echo "WARNING: IPv4-looking values found (check they are not real addresses):"
  printf '%s\n' "$ipout" | head -n 40 | sed 's/^/    /'
fi

echo "Scanned $nfiles file(s) against $npatterns deny-list string(s)."
if [ "$npatterns" -eq 0 ]; then
  echo "ERROR: the deny-list is empty - nothing was checked." >&2
  exit 2
fi
if [ "$hits" -gt 0 ]; then
  echo "FAILED: $hits deny-listed string(s) present. Do not commit or push."
  exit 1
fi
echo "OK: no deny-listed string found."
exit 0
