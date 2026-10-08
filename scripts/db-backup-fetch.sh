#!/usr/bin/env bash
# db-backup-fetch.sh - copy database dumps from the backup volume to this machine.
#
# The backup volume is in the same cluster as the database; keep copies
# elsewhere. This starts a short-lived pod that mounts the backup volume
# read-only (data zones only), copies the dumps with `oc cp`, and deletes the pod.
#
# Usage:
#   scripts/db-backup-fetch.sh [--all] [--dest <dir>] [--env local/deploy.env]
#     default: newest dump only;  --all: every dump on the volume
#     default destination: local/db-dumps/ (git-ignored, mode 700)

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ENV_ARG=""; ALL=0; DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need_tools oc
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

DEST="${DEST:-$LOCAL_DIR/db-dumps}"
# A new directory is private; an existing one keeps its permissions.
[ -d "$DEST" ] || (umask 077 && mkdir -p "$DEST")
pod="grafana-db-backup-fetch"
image="$(ocn get statefulset grafana-postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
zl="$(printf '"%s",' "${DATA_ZONE_LIST[@]}")"

ocn delete pod "$pod" --ignore-not-found --wait=true >/dev/null
cat <<EOF | ocn apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    app.kubernetes.io/name: grafana-db-backup-fetch
    app.kubernetes.io/part-of: grafana
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  automountServiceAccountToken: false
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: "$ZONE_LABEL", operator: In, values: [${zl%,}]}
  containers:
    - name: fetch
      image: $image
      command: ["sleep", "3600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      volumeMounts:
        - {name: backup, mountPath: /backup, readOnly: true}
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: grafana-db-backup, readOnly: true}
EOF
trap 'ocn delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
ocn wait --for=condition=Ready "pod/$pod" --timeout=5m >/dev/null || die "fetch pod not ready (backup volume in use by a running job?)"

if [ "$ALL" = 1 ]; then
  files="$(ocn exec "$pod" -- sh -c 'ls -1 /backup/grafana-*.dump' </dev/null)"
else
  files="$(ocn exec "$pod" -- sh -c 'ls -1t /backup/grafana-*.dump | head -n 1' </dev/null)"
fi
[ -n "$files" ] || die "no dump on the backup volume"
for f in $files; do
  ocn cp "$pod:$f" "$DEST/$(basename "$f")" >/dev/null
  ok "copied $(basename "$f") ($(wc -c < "$DEST/$(basename "$f")") bytes) to $DEST"
done
