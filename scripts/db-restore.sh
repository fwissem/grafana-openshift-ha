#!/usr/bin/env bash
# db-restore.sh - restore the Grafana database from a dump on the backup volume.
#
# DISRUPTIVE: Grafana is scaled to 0 during the restore (a few minutes) and the
# current database content is replaced by the dump.
#
# Steps: scale Grafana to 0 -> run the restore Job (refuses to run while other
# connections exist) -> scale Grafana back -> wait until ready.
#
# Usage:
#   scripts/db-restore.sh --list                         # list available dumps
#   scripts/db-restore.sh --file latest   [--yes]        # newest dump
#   scripts/db-restore.sh --file grafana-YYYYmmdd-HHMMSS.dump [--yes]
#   (--env local/deploy.env as for the other scripts)
#
# Needs local/render/restore, created by scripts/install.sh (--check is enough).

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ENV_ARG=""; FILE=""; LIST=0; ASSUME_YES=0
# shellcheck disable=SC2034  # ASSUME_YES is read by confirm() in lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_tools oc sed
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

# Last backup job logs list the dumps kept on the volume.
if [ "$LIST" = 1 ]; then
  last="$(ocn get jobs -l app.kubernetes.io/name=grafana-db-backup --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -n 1)"
  [ -n "$last" ] || last="$(ocn get jobs --sort-by=.metadata.creationTimestamp -o name | grep grafana-db-backup | tail -n 1 || true)"
  [ -n "$last" ] || die "no backup job found; run scripts/db-backup-now.sh"
  log "dumps on the backup volume (from $last):"
  ocn logs "$last" | sed -n '/backups kept:/,$p'
  exit 0
fi

[ -n "$FILE" ] || die "--file <name|latest> is required (see --list)"
case "$FILE" in
  latest|grafana-[0-9]*-[0-9]*.dump) ;;
  *) die "invalid dump name: $FILE" ;;
esac
[ -r "$RENDER_DIR/restore/kustomization.yaml" ] || die "run scripts/install.sh --check first (renders local/render/restore)"

replicas="$(ocn get deployment "$RELEASE" -o jsonpath='{.spec.replicas}')"
confirm "Scale Grafana ($replicas replicas) to 0 and REPLACE the database with dump '$FILE'?"

ocn scale "deployment/$RELEASE" --replicas=0 >/dev/null
log "waiting for Grafana pods to stop"
ocn wait --for=delete pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=$RELEASE" --timeout=5m || true

ocn delete job grafana-db-restore --ignore-not-found >/dev/null
oc kustomize "$RENDER_DIR/restore" \
  | sed "s/value: latest/value: \"$FILE\"/" \
  | ocn apply -f - >/dev/null
log "restore job started"
rc=0
ocn wait --for=condition=complete job/grafana-db-restore --timeout=30m || rc=1
ocn logs job/grafana-db-restore || true

log "scaling Grafana back to $replicas"
ocn scale "deployment/$RELEASE" --replicas="$replicas" >/dev/null
ocn rollout status "deployment/$RELEASE" --timeout=15m
ocn delete job grafana-db-restore --ignore-not-found >/dev/null
[ "$rc" -eq 0 ] || die "restore job failed: Grafana restarted on the previous database content"
ok "database restored from $FILE, Grafana running"
