#!/usr/bin/env bash
# db-backup-now.sh - run the Grafana database backup now (same job as the daily CronJob).
#
# Usage: scripts/db-backup-now.sh [--env local/deploy.env]
#
# The dump goes to the backup volume (grafana-db-backup PVC). Copy dumps
# off-cluster regularly (see docs/RUNBOOK.md).

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ENV_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_tools oc
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

job="grafana-db-backup-manual-$(date +%Y%m%d-%H%M%S)"
ocn create job "$job" --from=cronjob/grafana-db-backup >/dev/null
log "job $job started"
if wait_job "$job" 1800; then
  ocn logs "job/$job"
  ok "backup done"
else
  ocn logs "job/$job" || true
  die "backup job $job did not complete"
fi
