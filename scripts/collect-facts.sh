#!/usr/bin/env bash
# collect-facts.sh - phase 1: collect the facts needed to finalise the design.
#
# STRICTLY READ-ONLY: only `oc get`, `oc version`, `oc whoami`, `oc auth can-i`.
# Nothing is created, changed or deleted on any cluster. Secret VALUES are
# never read: only secret names and ConfigMap key names.
#
# The current Grafana and the new one live on DIFFERENT clusters, so the script
# runs once per cluster:
#
#   source  the cluster running the Grafana to replace
#           (how it stores data, what it is made of)
#   target  the cluster that will run the new Grafana
#           (zones, storage, OAuth, monitoring, image mirrors, rights)
#
# Usage (RHEL bastion, bash):
#   scripts/collect-facts.sh source -n <namespace-of-current-grafana> [--kubeconfig <file>]
#   scripts/collect-facts.sh target -n <namespace-for-new-grafana>    [--kubeconfig <file>] [-z <zone-label>]
#
#   -n            namespace (required)
#   --kubeconfig  kubeconfig of that cluster (default: $KUBECONFIG / current oc login)
#   -z            node label carrying the zone (target only,
#                 default: topology.kubernetes.io/zone)
#
# Output: ./local/collect-<mode>-<timestamp>/ (git-ignored). It contains REAL
# names of your environment: never copy it into a tracked file.

set -u

usage() { sed -n '2,27p' "$0"; }

MODE="${1:-}"
case "$MODE" in
  source|target) shift ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: first argument must be 'source' or 'target'." >&2; usage >&2; exit 2 ;;
esac

NS=""
KCFG=""
ZONE_LABEL="topology.kubernetes.io/zone"
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS="${2:-}"; shift 2 ;;
    --kubeconfig) KCFG="${2:-}"; shift 2 ;;
    -z) ZONE_LABEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$NS" ] || { echo "ERROR: -n <namespace> is required." >&2; exit 2; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found in PATH." >&2; exit 2; }
if [ -n "$KCFG" ]; then
  [ -r "$KCFG" ] || { echo "ERROR: kubeconfig not readable: $KCFG" >&2; exit 2; }
  export KUBECONFIG="$KCFG"
fi

# Refuse to run if this file was saved with Windows line endings.
if grep -q $'\r' "$0"; then
  echo "ERROR: $0 has Windows line endings (CRLF). Clone the repo with git on Linux." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/local/collect-$MODE-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || exit 2

# run <file> <command...> : one read-only command, stdout+stderr and rc kept.
run() {
  local name="$1"; shift
  {
    printf '$ %s\n' "$*"
    "$@" </dev/null 2>&1
    printf '[rc=%s]\n' "$?"
  } > "$OUT/$name.txt"
  printf '  %-34s %s\n' "$name" "$(tail -n 1 "$OUT/$name.txt")"
}

echo "Read-only collection ($MODE) -> $OUT"
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'not logged in')"

# --- Common: where are we ---------------------------------------------------------
run 00-whoami            oc whoami
run 00-server            oc whoami --show-server
run 00-version           oc version
run 00-clusterversion    oc get clusterversion

if [ "$MODE" = "source" ]; then
  # --- Current Grafana: how it stores data, what it is made of --------------------
  run 10-workloads       oc -n "$NS" get deployment,statefulset,pod,svc,route,pvc,configmap -o wide
  run 10-images          oc -n "$NS" get pods -o custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image
  # Volumes and mounts only (no env values, so no secret leaks into the output).
  run 11-volumes         oc -n "$NS" get deployment,statefulset -o "jsonpath={range .items[*]}{.kind}/{.metadata.name}{'\n'}  replicas: {.spec.replicas}{'\n'}  volumes: {.spec.template.spec.volumes}{'\n'}  mounts: {range .spec.template.spec.containers[*]}{.name}={.volumeMounts}{' '}{end}{'\n'}{end}"
  run 12-env-names       oc -n "$NS" get deployment,statefulset -o "jsonpath={range .items[*]}{.kind}/{.metadata.name}: {range .spec.template.spec.containers[*]}{.env[*].name}{' '}{end}{'\n'}{end}"
  # ConfigMap names and KEY names only (values may hold passwords or tokens).
  run 13-configmap-keys  oc -n "$NS" get configmap -o go-template='{{range .items}}{{.metadata.name}}: {{range $k, $v := .data}}{{$k}} {{end}}{{"\n"}}{{end}}'
  run 14-secret-names    oc -n "$NS" get secret -o custom-columns=NAME:.metadata.name,TYPE:.type
  run 15-routes          oc -n "$NS" get route -o custom-columns=NAME:.metadata.name,HOST:.spec.host,TLS:.spec.tls.termination
  run 16-quota           oc -n "$NS" get resourcequota,limitrange
fi

if [ "$MODE" = "target" ]; then
  # --- Storage ---------------------------------------------------------------------
  run 20-storageclasses  oc get storageclass
  run 21-storageclass-y  oc get storageclass -o yaml

  # --- Zones / nodes -----------------------------------------------------------------
  run 30-nodes-zones     oc get nodes -L "$ZONE_LABEL" -L node-role.kubernetes.io/worker -L node-role.kubernetes.io/infra
  run 31-nodes-taints    oc get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key,EFFECT:.spec.taints[*].effect
  run 32-zone-values     oc get nodes -o "jsonpath={range .items[*]}{.metadata.labels.${ZONE_LABEL//./\\.}}{'\n'}{end}"

  # --- Target namespace ----------------------------------------------------------------
  run 40-ns              oc get namespace "$NS" --show-labels
  run 41-ns-content      oc -n "$NS" get all,pvc,configmap,networkpolicy,resourcequota,limitrange

  # --- Exposure: router, domain --------------------------------------------------------
  run 50-ingress-domain  oc get ingresses.config/cluster -o "jsonpath={.spec.domain}"
  run 51-ingresscontrol  oc -n openshift-ingress-operator get ingresscontroller -o custom-columns=NAME:.metadata.name,DOMAIN:.status.domain,SELECTOR:.spec.namespaceSelector,ROUTESEL:.spec.routeSelector
  run 52-router-ns       oc get namespace openshift-ingress --show-labels
  run 53-monitoring-ns   oc get namespace openshift-monitoring openshift-user-workload-monitoring --show-labels

  # --- Authentication -----------------------------------------------------------------
  run 60-oauth           oc get oauth cluster -o yaml
  run 61-oauth-route     oc -n openshift-authentication get route oauth-openshift -o "jsonpath={.spec.host}"
  run 62-groups          oc get groups
  run 63-oauthclients    oc get oauthclient -o custom-columns=NAME:.metadata.name,REDIRECTS:.redirectURIs
  run 64-can-i-oauthcl   oc auth can-i create oauthclients
  run 65-ingress-ca      oc -n openshift-config-managed get configmap default-ingress-cert -o "jsonpath={.metadata.name} keys: {.data}"

  # --- Monitoring -------------------------------------------------------------------
  run 70-uwm-config      oc -n openshift-monitoring get configmap cluster-monitoring-config -o "jsonpath={.data.config\.yaml}"
  run 71-uwm-pods        oc -n openshift-user-workload-monitoring get pods
  run 72-thanos-route    oc -n openshift-monitoring get route

  # --- Images: can the cluster pull Docker Hub and registry.redhat.io ------------------
  run 80-image-config    oc get image.config.openshift.io/cluster -o yaml
  run 81-idms-itms       oc get imagedigestmirrorset,imagetagmirrorset -o yaml
  run 82-icsp            oc get imagecontentsourcepolicy -o yaml

  # --- Security / network ---------------------------------------------------------------
  run 90-scc-restricted  oc get scc restricted-v2 -o yaml
  run 91-network         oc get network.config.openshift.io/cluster -o "jsonpath={.spec.networkType}"

  # --- Rights of the current user in the target namespace -------------------------------
  run 95-can-i-deploy    oc -n "$NS" auth can-i create deployments
  run 96-can-i-sts       oc -n "$NS" auth can-i create statefulsets
  run 97-can-i-netpol    oc -n "$NS" auth can-i create networkpolicies
  run 98-can-i-svcmon    oc -n "$NS" auth can-i create servicemonitors.monitoring.coreos.com
  run 99-can-i-route     oc -n "$NS" auth can-i create routes.route.openshift.io
fi

echo
echo "Done. Files are in: $OUT"
echo "They contain real names: keep them local (./local/ is git-ignored)."
