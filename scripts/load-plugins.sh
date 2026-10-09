#!/usr/bin/env bash
# load-plugins.sh - put the Grafana plugins of the repository on the volume
# grafana-plugins, from which every Grafana pod copies them at start.
#
# The cluster cannot reach grafana.com and Grafana runs from the official image,
# so the plugins travel with the repository (plugins/*.zip, checked against
# values/plugins.lock) and are copied to a shared volume:
#
#   1. check every archive against its SHA-256 and unpack it here
#   2. create the PVC grafana-plugins (ReadWriteMany, PLUGINS_STORAGE_CLASS)
#   3. start a short-lived pod in a data zone with that volume (PostgreSQL image,
#      already used by the deployment) and copy the plugins with `oc cp`
#   4. switch the volume to the new set in one rename, keep the previous set
#   5. record the loaded set in the ConfigMap grafana-plugins (install.sh checks it)
#
#   --check   show what would be done (no change)
#   --apply   do it. Nothing happens if the same set is already loaded.
#
# Usage:
#   scripts/load-plugins.sh --check [--env local/deploy.env]
#   scripts/load-plugins.sh --apply [--env local/deploy.env] [--yes] [--force]

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=""; ENV_ARG=""; ASSUME_YES=0; FORCE=0
# shellcheck disable=SC2034  # ASSUME_YES is read by confirm() in lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,22p' "$0"; exit 2; }

need_tools oc sha256sum
command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || die "need unzip or python3 to unpack the plugins"
check_line_endings
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE does not exist"

# ------------------------------------------------------------------------------------
# Plan
# ------------------------------------------------------------------------------------
verify_plugin_archives > /dev/null
while read -r pid pver; do ok "plugin $pid $pver (SHA-256 checked)"; done < <(verify_plugin_archives)
HASH="$(plugins_hash)"
loaded=""
if exists configmap grafana-plugins; then
  loaded="$(ocn get configmap grafana-plugins -o jsonpath='{.data.hash}')"
fi
if [ "$loaded" = "$HASH" ] && [ "$FORCE" = 0 ]; then
  ok "plugin set $HASH is already on the volume grafana-plugins: nothing to do (--force to reload)"
  exit 0
fi
log "plugin set to load: $HASH (loaded now: ${loaded:-none})"
log "Planned changes in namespace $NAMESPACE:"
if exists pvc grafana-plugins; then
  ok "PVC grafana-plugins exists"
else
  echo "    - create PVC grafana-plugins (ReadWriteMany, $PLUGINS_STORAGE_CLASS, $PLUGINS_VOLUME_SIZE)"
fi
echo "    - start pod grafana-plugins-loader in a data zone (${DATA_ZONE_LIST[*]}), copy the plugins, delete the pod"
echo "    - record set $HASH in ConfigMap grafana-plugins"
if [ "$MODE" = check ]; then
  log "--check: nothing changed. Run with --apply to load the plugins."
  exit 0
fi
confirm "Load plugin set $HASH on the volume grafana-plugins?"

# ------------------------------------------------------------------------------------
# Unpack here
# ------------------------------------------------------------------------------------
init_secure_tmp
SRC="$SECURE_TMP/new-$HASH"
mkdir -p "$SRC"
while read -r pid pver; do
  zip="$PLUGINS_DIR/$pid-$pver.zip"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip" -d "$SRC"
  else
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$SRC"
  fi
  [ -r "$SRC/$pid/plugin.json" ] || die "$zip does not contain $pid/plugin.json"
done < <(verify_plugin_archives)
chmod -R a+rX "$SRC"

# ------------------------------------------------------------------------------------
# Volume and loader pod (data zones only)
# ------------------------------------------------------------------------------------
zones_yaml="$(printf '"%s", ' "${DATA_ZONE_LIST[@]}")"; zones_yaml="[${zones_yaml%, }]"
cat <<EOF | ocn apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-plugins
  labels:
    app.kubernetes.io/name: grafana-plugins
    app.kubernetes.io/part-of: grafana
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: "$PLUGINS_STORAGE_CLASS"
  resources:
    requests:
      storage: "$PLUGINS_VOLUME_SIZE"
EOF
ok "PVC grafana-plugins applied"

POD=grafana-plugins-loader
trap 'ocn delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; rm -rf "$SECURE_TMP"' EXIT
ocn delete pod "$POD" --ignore-not-found --wait=true >/dev/null
cat <<EOF | ocn apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels:
    app.kubernetes.io/name: grafana-plugins-loader
    app.kubernetes.io/part-of: grafana
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  activeDeadlineSeconds: 1800
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: "$ZONE_LABEL", operator: In, values: $zones_yaml}
  securityContext:
    runAsNonRoot: true
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: loader
      image: "$POSTGRES_IMAGE"
      command: ["sleep", "1800"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 256Mi}
      volumeMounts:
        - {name: plugins, mountPath: /plugins}
  volumes:
    - name: plugins
      persistentVolumeClaim: {claimName: grafana-plugins}
EOF
ocn wait --for=condition=Ready "pod/$POD" --timeout=5m >/dev/null \
  || die "loader pod not ready (PVC not bound? oc -n $NAMESPACE describe pvc grafana-plugins)"
ok "loader pod ready"

ocn exec "$POD" -- rm -rf "/plugins/.new-$HASH" </dev/null
ocn cp "$SRC" "$POD:/plugins/.new-$HASH" >/dev/null || die "oc cp to the loader pod failed"
# Switch in one rename. live.old is kept as the previous set.
ocn exec "$POD" -- sh -c "
  set -e
  cd /plugins
  chmod -R a+rX .new-$HASH 2>/dev/null || echo 'warning: chmod refused by the volume; files keep the mode set by oc cp' >&2
  rm -rf live.old
  if [ -d live ]; then mv live live.old; fi
  mv .new-$HASH live
  echo $HASH > live.hash.tmp && mv live.hash.tmp live.hash
" </dev/null || die "could not switch the plugin set on the volume"

# Check what the pods will copy.
while read -r pid pver; do
  got="$(ocn exec "$POD" -- sh -c "grep -o '\"version\": *\"[^\"]*\"' /plugins/live/$pid/plugin.json | head -n 1" </dev/null | sed 's/.*"\([^"]*\)"$/\1/')"
  [ "$got" = "$pver" ] || die "$pid on the volume has version '$got', expected $pver"
  ok "$pid $pver on the volume"
done < <(verify_plugin_archives)

list="$(verify_plugin_archives | tr ' ' '@' | tr '\n' ' ')"
ocn create configmap grafana-plugins --from-literal=hash="$HASH" --from-literal=plugins="${list% }" \
  --dry-run=client -o yaml | ocn apply -f - >/dev/null
ok "plugin set $HASH recorded in ConfigMap grafana-plugins"
log "Next: scripts/install.sh --check (pods that start from now on copy this set)"
