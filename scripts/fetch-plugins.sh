#!/usr/bin/env bash
# fetch-plugins.sh - download the Grafana plugins listed in values/plugins.lock
# and check them against their SHA-256, for an internal mirror.
#
# Only needed when the Grafana pods cannot reach grafana.com (see
# docs/PLUGINS.md). Run it on any machine with Internet access, then upload the
# zips to the web server or repository whose URL is PLUGIN_MIRROR_URL. File
# names are <id>-<version>.zip, which is what Grafana asks the mirror for.
#
# Usage:
#   scripts/fetch-plugins.sh [--dest local/plugins]
#   (HTTPS_PROXY is honoured by curl if you need a proxy)

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need_tools curl sha256sum
DEST="${DEST:-$LOCAL_DIR/plugins}"
mkdir -p "$DEST"
LOCK="$REPO_ROOT/values/plugins.lock"

n=0
while read -r pid pver psum _; do
  case "$pid" in ''|'#'*) continue ;; esac
  out="$DEST/$pid-$pver.zip"
  curl -fsSL --retry 3 -o "$out.tmp" "https://grafana.com/api/plugins/$pid/versions/$pver/download" \
    || die "download of $pid $pver failed"
  got="$(sha256sum "$out.tmp" | cut -d' ' -f1)"
  if [ "$got" != "$psum" ]; then
    rm -f "$out.tmp"
    die "$pid $pver: SHA-256 is $got, plugins.lock expects $psum"
  fi
  mv "$out.tmp" "$out"
  ok "$pid $pver ($(wc -c < "$out") bytes, SHA-256 checked)"
  n=$((n + 1))
done < "$LOCK"

[ "$n" -gt 0 ] || die "no plugin listed in $LOCK"
log "Upload the $n zip file(s) of $DEST to the mirror, keeping their names,"
log "then set PLUGIN_MIRROR_URL in local/deploy.env and run scripts/install.sh --apply."
