#!/usr/bin/env bash
# collect-facts.sh - phase 1: collect the facts needed to finalise the design.
#
# STRICTLY READ-ONLY: only `oc get`, `oc version`, `oc whoami`, `oc auth can-i`.
# Nothing is created, changed or deleted on the cluster.
#
# The output contains REAL names of your environment. It is written under
# ./local/ which is git-ignored. Never copy it into a tracked file.
#
# Usage:
#   scripts/collect-facts.sh -o <old-grafana-namespace> [-n <new-namespace>] [-z <zone-label>]
#
#   -o  namespace of the Grafana instance to replace (required)
#   -n  namespace planned for the new instance (default: grafana)
#   -z  node label that carries the zone (default: topology.kubernetes.io/zone)
#
# Uses the current `oc` context (KUBECONFIG / oc login). Check it first:
#   oc whoami --show-server

set -u

OLD_NS=""
NEW_NS="grafana"
ZONE_LABEL="topology.kubernetes.io/zone"

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OLD_NS="${2:-}"; shift 2 ;;
    -n) NEW_NS="${2:-}"; shift 2 ;;
    -z) ZONE_LABEL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$OLD_NS" ]; then
  echo "ERROR: -o <old-grafana-namespace> is required." >&2
  exit 2
fi
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found in PATH." >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/local/collect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || exit 2

# run <file> <command...> : run one read-only command, keep stdout+stderr and the rc.
run() {
  local name="$1"; shift
  {
    printf '$ %s\n' "$*"
    "$@" </dev/null 2>&1
    printf '[rc=%s]\n' "$?"
  } > "$OUT/$name.txt"
  printf '  %-34s %s\n' "$name" "$(tail -n 1 "$OUT/$name.txt")"
}

echo "Read-only collection -> $OUT"

# --- 0. Where are we ---------------------------------------------------------
run 00-whoami            oc whoami
run 00-server            oc whoami --show-server
run 00-version           oc version
run 00-clusterversion    oc get clusterversion

# --- 1. Storage --------------------------------------------------------------
run 10-storageclasses    oc get storageclass
run 10-storageclasses-y  oc get storageclass -o yaml

# --- 2. Zones / nodes --------------------------------------------------------
run 20-nodes-zones       oc get nodes -L "$ZONE_LABEL" -L node-role.kubernetes.io/worker -L node-role.kubernetes.io/infra
run 20-nodes-taints      oc get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key

# --- 3. Current Grafana (the one that loses dashboards) ----------------------
run 30-old-workloads     oc -n "$OLD_NS" get deployment,statefulset,pod,svc,route,pvc,configmap -o wide
run 30-old-images        oc -n "$OLD_NS" get pods -o custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image
# Volumes and mounts only (no env values, so no secret leaks into the output).
run 30-old-volumes       oc -n "$OLD_NS" get deployment,statefulset -o "jsonpath={range .items[*]}{.kind}/{.metadata.name}{'\n'}  replicas: {.spec.replicas}{'\n'}  volumes: {.spec.template.spec.volumes}{'\n'}  mounts: {range .spec.template.spec.containers[*]}{.name}={.volumeMounts}{' '}{end}{'\n'}{end}"
run 30-old-env-names     oc -n "$OLD_NS" get deployment,statefulset -o "jsonpath={range .items[*]}{.kind}/{.metadata.name}: {range .spec.template.spec.containers[*]}{.env[*].name}{' '}{end}{'\n'}{end}"
# ConfigMap names and key names only (values may hold passwords or tokens).
run 30-old-configmaps    oc -n "$OLD_NS" get configmap -o go-template='{{range .items}}{{.metadata.name}}: {{range $k, $v := .data}}{{$k}} {{end}}{{"\n"}}{{end}}'
run 30-old-secrets-names oc -n "$OLD_NS" get secret -o custom-columns=NAME:.metadata.name,TYPE:.type
run 30-old-quota         oc -n "$OLD_NS" get resourcequota,limitrange

# --- 4. Target namespace -----------------------------------------------------
run 40-new-ns            oc get namespace "$NEW_NS" --show-labels
run 40-new-content       oc -n "$NEW_NS" get all,pvc,configmap,networkpolicy

# --- 5. Authentication -------------------------------------------------------
run 50-oauth             oc get oauth cluster -o yaml
run 50-groups            oc get groups
run 50-oauthclients      oc get oauthclient
run 50-can-i-oauthclient oc auth can-i create oauthclients

# --- 6. Monitoring -----------------------------------------------------------
run 60-uwm-config        oc -n openshift-monitoring get configmap cluster-monitoring-config -o "jsonpath={.data.config\.yaml}"
run 60-uwm-pods          oc -n openshift-user-workload-monitoring get pods
run 60-thanos-route      oc -n openshift-monitoring get route

# --- 7. Images: where can the cluster pull from ------------------------------
run 70-image-config      oc get image.config.openshift.io/cluster -o yaml
run 70-idms              oc get imagedigestmirrorset,imagetagmirrorset
run 70-icsp              oc get imagecontentsourcepolicy

# --- 8. Security / network ---------------------------------------------------
run 80-scc-restricted    oc get scc restricted-v2 -o yaml
run 80-ingresscontroller oc -n openshift-ingress-operator get ingresscontroller
run 80-network           oc get network.config.openshift.io/cluster -o "jsonpath={.spec.networkType}"

# --- 9. Rights of the current user in the target namespace -------------------
run 90-can-i-deploy      oc -n "$NEW_NS" auth can-i create deployments
run 90-can-i-netpol      oc -n "$NEW_NS" auth can-i create networkpolicies
run 90-can-i-svcmon      oc -n "$NEW_NS" auth can-i create servicemonitors

echo
echo "Done. Files are in: $OUT"
echo "They contain real names: keep them local (./local/ is git-ignored)."
