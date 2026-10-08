#!/usr/bin/env bash
# install.sh - deploy or update Grafana HA (Helm) and its platform objects (oc apply -k).
#
#   --check     render everything and show `oc diff` against the cluster (no change)
#   --apply     back up the current state, apply the platform objects, then
#               `helm upgrade --install --wait`
#   --rollback  `helm rollback` to the revision recorded by the last --apply and
#               re-apply the platform objects saved by that --apply
#
# Inputs (all private, git-ignored except the public values files):
#   local/deploy.env              environment settings (see deploy.env.example)
#   values/values.yaml            public defaults
#   values/values-openshift.yaml  OpenShift specifics
#   values/values-local.yaml      private: datasources, overrides
#   charts/grafana/               chart downloaded and untarred by hand
#
# Outputs: local/render/ (rendered manifests), local/backups/<timestamp>/.
#
# Usage:
#   scripts/install.sh --check    [--env local/deploy.env]
#   scripts/install.sh --apply    [--env local/deploy.env] [--yes]
#   scripts/install.sh --rollback [--env local/deploy.env] [--yes]

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=""; ENV_ARG=""; ASSUME_YES=0
# shellcheck disable=SC2034  # ASSUME_YES is read by confirm() in lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --rollback) MODE=rollback; shift ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,24p' "$0"; exit 2; }

need_tools oc helm sed grep jq
check_line_endings
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

CHART_DIR="$REPO_ROOT/charts/grafana"
VALUES_LOCAL="$REPO_ROOT/values/values-local.yaml"
OVERLAY_DIR="$RENDER_DIR/overlay"
BACKUP_ROOT="$LOCAL_DIR/backups"
mkdir -p "$RENDER_DIR" "$OVERLAY_DIR" "$BACKUP_ROOT"

# ------------------------------------------------------------------------------------
# Rollback
# ------------------------------------------------------------------------------------
if [ "$MODE" = rollback ]; then
  last="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  [ -n "$last" ] || die "no backup in $BACKUP_ROOT"
  log "Helm history of $RELEASE:"
  helm history "$RELEASE" -n "$NAMESPACE" --max 5 || die "release $RELEASE not found"
  rev="$(cat "$last/helm-revision-before" 2>/dev/null || true)"
  if [ -n "$rev" ]; then
    confirm "Roll back Helm release $RELEASE to revision $rev and re-apply the platform objects from $last?"
    helm rollback "$RELEASE" "$rev" -n "$NAMESPACE" --wait --timeout 15m
    ok "helm rollback to revision $rev done"
  else
    warn "no Helm revision recorded in $last: the release did not exist before that --apply."
    warn "To remove it: helm uninstall $RELEASE -n $NAMESPACE"
    confirm "Re-apply only the platform objects from $last?"
  fi
  if [ -s "$last/platform-before.yaml" ]; then
    oc apply -f "$last/platform-before.yaml" >/dev/null
    ok "platform objects re-applied from $last/platform-before.yaml"
  else
    warn "no platform-before.yaml in $last (first install?): platform objects left as they are"
  fi
  ocn rollout status "deployment/$RELEASE" --timeout=15m
  exit 0
fi

# ------------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------------
[ -r "$CHART_DIR/Chart.yaml" ] || die "chart not found in $CHART_DIR (see README: helm pull ... --untar --untardir charts)"
chart_ver="$(sed -n 's/^version:[[:space:]]*//p' "$CHART_DIR/Chart.yaml" | tr -d '"' | head -n 1)"
[ "$chart_ver" = "$CHART_VERSION" ] || die "chart version is $chart_ver, deploy.env expects $CHART_VERSION"
ok "chart grafana $chart_ver"
[ -r "$VALUES_LOCAL" ] || die "missing $VALUES_LOCAL (copy values/values-local.yaml.example)"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE does not exist"
for s in grafana-admin grafana-db grafana-secret-key grafana-oauth; do
  ocn get secret "$s" >/dev/null 2>&1 || die "secret $s missing: run scripts/create-secrets.sh --apply first"
done
ocn get configmap grafana-oauth-ca >/dev/null 2>&1 || die "ConfigMap grafana-oauth-ca missing: run scripts/create-secrets.sh --apply"
ok "secrets and CA bundle present"
need_node_read
for z in "${DATA_ZONE_LIST[@]}"; do
  n="$(oc get nodes -l "$ZONE_LABEL=$z" -o name | wc -l)"
  [ "$n" -gt 0 ] || die "no node with $ZONE_LABEL=$z"
  ok "zone $z: $n node(s)"
done

# ------------------------------------------------------------------------------------
# Render: values generated from deploy.env
# ------------------------------------------------------------------------------------
GEN_VALUES="$RENDER_DIR/values-generated.yaml"
# Plugins: same list as values.yaml, downloaded from the mirror when one is set.
plugin_sync=""
if [ -n "${PLUGIN_MIRROR_URL:-}" ]; then
  while read -r pid pver _; do
    case "$pid" in ''|'#'*) continue ;; esac
    plugin_sync="$plugin_sync${plugin_sync:+,}$pid@$pver@${PLUGIN_MIRROR_URL%/}/$pid-$pver.zip"
  done < "$REPO_ROOT/values/plugins.lock"
  [ -n "$plugin_sync" ] || die "values/plugins.lock lists no plugin"
  ok "plugins from the mirror $PLUGIN_MIRROR_URL"
fi
tokens_version="$(ocn get secret grafana-datasource-tokens -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo none)"
{
  echo "# GENERATED by scripts/install.sh from $ENV_FILE - do not edit."
  if [ -n "$GRAFANA_IMAGE_REGISTRY" ]; then
    printf 'global:\n  imageRegistry: "%s"\n' "$GRAFANA_IMAGE_REGISTRY"
  fi
  printf 'replicas: %s\n' "$REPLICAS"
  # Changes when the datasource tokens change, so the pods restart and load them.
  printf 'podAnnotations:\n  checksum/datasource-tokens: "%s"\n' "$tokens_version"
  printf 'affinity:\n  nodeAffinity:\n    requiredDuringSchedulingIgnoredDuringExecution:\n'
  printf '      nodeSelectorTerms:\n        - matchExpressions:\n'
  printf '            - key: "%s"\n              operator: In\n              values:\n' "$ZONE_LABEL"
  for z in "${DATA_ZONE_LIST[@]}"; do printf '                - "%s"\n' "$z"; done
  printf 'topologySpreadConstraints:\n'
  for key in "$ZONE_LABEL" kubernetes.io/hostname; do
    when=DoNotSchedule; [ "$key" = "$ZONE_LABEL" ] && when=ScheduleAnyway
    printf '  - maxSkew: 1\n    topologyKey: "%s"\n    whenUnsatisfiable: %s\n    nodeTaintsPolicy: Honor\n' "$key" "$when"
    printf '    labelSelector:\n      matchLabels:\n        app.kubernetes.io/name: grafana\n        app.kubernetes.io/instance: "%s"\n' "$RELEASE"
    printf '    matchLabelKeys:\n      - pod-template-hash\n'
  done
  printf 'grafana.ini:\n  server:\n    root_url: "https://%s/"\n' "$ROUTE_HOST"
  printf '  auth.generic_oauth:\n'
  printf '    auth_url: "https://%s/oauth/authorize"\n' "$OAUTH_HOST"
  printf '    token_url: "https://%s/oauth/token"\n' "$OAUTH_HOST"
  printf '    role_attribute_path: "contains(groups[*], '"'"'%s'"'"') && '"'"'Admin'"'"' || contains(groups[*], '"'"'%s'"'"') && '"'"'Editor'"'"' || '"'"'Viewer'"'"'"\n' \
    "$GRAFANA_ADMIN_GROUP" "$GRAFANA_EDITOR_GROUP"
  if [ -n "${PLUGIN_MIRROR_URL:-}" ]; then
    printf '  plugins:\n    preinstall_sync: "%s"\n' "$plugin_sync"
  fi
} > "$GEN_VALUES"

# Release name must stay "grafana": manifests reference the service grafana and
# the headless service grafana-headless.
[ "$RELEASE" = grafana ] || die "RELEASE must be 'grafana' (platform manifests reference it)"

HELM_VALUES=(
  -f "$REPO_ROOT/values/values.yaml"
  -f "$REPO_ROOT/values/values-openshift.yaml"
  -f "$GEN_VALUES"
  -f "$VALUES_LOCAL"
)

# ------------------------------------------------------------------------------------
# Render: private overlay on top of manifests/overlays/openshift
# ------------------------------------------------------------------------------------
img="$POSTGRES_IMAGE"
case "$img" in
  *@sha256:*) img_name="${img%@*}"; img_ref="digest: ${img#*@}" ;;
  *:*)        img_name="${img%:*}"; img_ref="newTag: ${img##*:}" ;;
  *)          img_name="$img";      img_ref="newTag: latest" ;;
esac
zones_json="$(printf '"%s",' "${DATA_ZONE_LIST[@]}")"; zones_json="[${zones_json%,}]"
aff_value="{\"key\": \"$ZONE_LABEL\", \"operator\": \"In\", \"values\": $zones_json}"
AFF_POD=/spec/template/spec/affinity/nodeAffinity/requiredDuringSchedulingIgnoredDuringExecution/nodeSelectorTerms/0/matchExpressions/0
AFF_CRON=/spec/jobTemplate$AFF_POD

{
  echo "# GENERATED by scripts/install.sh from $ENV_FILE - do not edit."
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "namespace: $NAMESPACE"
  echo "resources:"
  echo "  - ../../../manifests/overlays/openshift"
  echo "images:"
  echo "  - name: registry.redhat.io/rhel9/postgresql-16"
  echo "    newName: $img_name"
  echo "    $img_ref"
  echo "patches:"
  echo "  - target: {kind: StatefulSet, name: grafana-postgresql}"
  echo "    patch: |-"
  echo "      - {op: add, path: /spec/volumeClaimTemplates/0/spec/storageClassName, value: \"$STORAGE_CLASS\"}"
  echo "      - {op: replace, path: /spec/volumeClaimTemplates/0/spec/resources/requests/storage, value: \"$DB_VOLUME_SIZE\"}"
  echo "      - {op: replace, path: $AFF_POD, value: $aff_value}"
  echo "  - target: {kind: CronJob, name: grafana-db-backup}"
  echo "    patch: |-"
  echo "      - {op: replace, path: $AFF_CRON, value: $aff_value}"
  echo "  - target: {kind: PersistentVolumeClaim, name: grafana-db-backup}"
  echo "    patch: |-"
  echo "      - {op: add, path: /spec/storageClassName, value: \"$BACKUP_STORAGE_CLASS\"}"
  echo "      - {op: replace, path: /spec/resources/requests/storage, value: \"$BACKUP_VOLUME_SIZE\"}"
  echo "  - target: {kind: Route, name: grafana}"
  echo "    patch: |-"
  echo "      - {op: replace, path: /spec/host, value: \"$ROUTE_HOST\"}"
  if [ "$UWM_ENABLED" != true ]; then
    echo "  - target: {kind: ServiceMonitor, name: grafana}"
    echo "    patch: |-"
    echo "      \$patch: delete"
    echo "      apiVersion: monitoring.coreos.com/v1"
    echo "      kind: ServiceMonitor"
    echo "      metadata: {name: grafana}"
    echo "  - target: {kind: PrometheusRule, name: grafana}"
    echo "    patch: |-"
    echo "      \$patch: delete"
    echo "      apiVersion: monitoring.coreos.com/v1"
    echo "      kind: PrometheusRule"
    echo "      metadata: {name: grafana}"
  fi
} > "$OVERLAY_DIR/kustomization.yaml"

# Restore job overlay (used by scripts/db-restore.sh), same environment patches.
mkdir -p "$RENDER_DIR/restore"
{
  echo "# GENERATED by scripts/install.sh from $ENV_FILE - do not edit."
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "namespace: $NAMESPACE"
  echo "resources:"
  echo "  - ../../../manifests/restore"
  echo "images:"
  echo "  - name: registry.redhat.io/rhel9/postgresql-16"
  echo "    newName: $img_name"
  echo "    $img_ref"
  echo "patches:"
  echo "  - target: {kind: Job, name: grafana-db-restore}"
  echo "    patch: |-"
  echo "      - {op: replace, path: $AFF_POD, value: $aff_value}"
} > "$RENDER_DIR/restore/kustomization.yaml"

PLATFORM="$RENDER_DIR/platform.yaml"
GRAFANA="$RENDER_DIR/grafana.yaml"
oc kustomize "$OVERLAY_DIR" | sed "s/__NAMESPACE__/$NAMESPACE/g" > "$PLATFORM" \
  || die "kustomize render failed"
helm template "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" "${HELM_VALUES[@]}" > "$GRAFANA" \
  || die "helm template failed"
ok "rendered $(grep -c '^kind:' "$PLATFORM") platform objects and $(grep -c '^kind:' "$GRAFANA") Grafana objects in $RENDER_DIR"

# Never in the quorum zone: every rendered workload must carry the zone affinity.
for f in "$PLATFORM" "$GRAFANA"; do
  workloads="$(grep -cE '^kind: (Deployment|StatefulSet|CronJob|Job)$' "$f" || true)"
  zoned="$(grep -c "$ZONE_LABEL" "$f" || true)"
  [ "$workloads" -eq 0 ] || [ "$zoned" -ge "$workloads" ] || die "a workload in $f has no zone affinity"
done
ok "every workload is pinned to the data zones: ${DATA_ZONE_LIST[*]}"

# ------------------------------------------------------------------------------------
# Diff (always)
# ------------------------------------------------------------------------------------
log "Diff of the platform objects (oc diff):"
set +e
oc diff -f "$PLATFORM"; rc1=$?
log "Diff of the Grafana release (helm template | oc diff):"
ocn diff -f "$GRAFANA"; rc2=$?
set -e
[ "$rc1" -le 1 ] && [ "$rc2" -le 1 ] || die "oc diff failed (rc=$rc1/$rc2): check permissions and CRDs"
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then ok "no difference with the cluster"; fi

if [ "$MODE" = check ]; then
  log "--check: nothing changed. Run with --apply to deploy."
  exit 0
fi

# ------------------------------------------------------------------------------------
# Apply
# ------------------------------------------------------------------------------------
confirm "Deploy to namespace $NAMESPACE on $EXPECTED_API_SERVER?"
BK="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
# Current objects, without the fields that would make a later re-apply conflict.
oc get -f "$PLATFORM" -o yaml --ignore-not-found 2>/dev/null \
  | grep -vE '^[[:space:]]+(resourceVersion|uid|creationTimestamp|generation):' > "$BK/platform-before.yaml" || true
helm get values "$RELEASE" -n "$NAMESPACE" -o yaml > "$BK/helm-values-before.yaml" 2>/dev/null || true
helm history "$RELEASE" -n "$NAMESPACE" > "$BK/helm-history-before.txt" 2>/dev/null || true
# Revision to come back to with --rollback (absent on a first install).
helm status "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.version // empty' > "$BK/helm-revision-before" || true
cp "$PLATFORM" "$GRAFANA" "$GEN_VALUES" "$BK/"
ok "backup of the current state in $BK"

oc apply -f "$PLATFORM"
ocn rollout status statefulset/grafana-postgresql --timeout=10m
ok "PostgreSQL ready"

helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" "${HELM_VALUES[@]}" --wait --timeout 15m
ocn rollout status "deployment/$RELEASE" --timeout=15m
ok "Grafana ready: https://$ROUTE_HOST/"
log "Next: tests/openshift/acceptance.sh"
