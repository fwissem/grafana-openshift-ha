#!/usr/bin/env bash
# acceptance.sh - acceptance test of a deployed Grafana HA on OpenShift (non-production).
#
# Same checks as the local kind test, adapted to a shared cluster (no node drain).
# It creates test content (folders/dashboards/user prefixed "acc-") and removes it
# at the end. Everything else is read-only except where a test says so:
#   A08 deletes all Grafana pods, A09 deletes one pod, A10 deletes the pods of one
#   zone, A11 starts two short-lived probe pods, A12 runs a backup job,
#   A13 (only with --with-restore) restores the database from that backup.
#
#   A01 replicas ready                     A08 all pods deleted: content kept
#   A02 2 per data zone, quorum zone empty A09 one pod killed under load
#   A03 state in PostgreSQL, no PVC        A10 all pods of one zone killed under load
#   A04 alerting cluster = all replicas    A11 only labelled pods reach PostgreSQL
#   A05 route: HTTPS, HTTP redirected      A12 backup job succeeds
#   A06 OpenShift login offered/redirects  A13 restore brings a deleted dashboard back
#   A07 anonymous: shared yes, restricted no; same content on every replica
#   A14 no pod of the namespace outside the data zones
#
# Usage (RHEL bastion):
#   tests/openshift/acceptance.sh [--env local/deploy.env] [--with-restore]
# Report: local/acceptance-<timestamp>.txt

set -euo pipefail
# shellcheck source=../../scripts/lib/common.sh
. "$(dirname "$0")/../../scripts/lib/common.sh"

ENV_ARG=""; WITH_RESTORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --with-restore) WITH_RESTORE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
need_tools oc curl base64 grep
check_line_endings
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

REPORT="$LOCAL_DIR/acceptance-$(date +%Y%m%d-%H%M%S).txt"
URL="https://$ROUTE_HOST"
SEL="app.kubernetes.io/name=grafana,app.kubernetes.io/instance=$RELEASE"
init_secure_tmp; TMP="$SECURE_TMP"
PASS=0; WARN=0; FAIL=0

result() {  # result <id> <PASS|WARN|FAIL> <text>
  case "$2" in PASS) PASS=$((PASS + 1)) ;; WARN) WARN=$((WARN + 1)) ;; *) FAIL=$((FAIL + 1)) ;; esac
  printf '%-4s %s %s\n' "$2" "$1" "$3" | tee -a "$REPORT"
}

# Credentials and CA in private temp files (never on a command line).
ocn get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d > "$TMP/pw"
ocn get configmap grafana-oauth-ca -o jsonpath='{.data.ca\.crt}' > "$TMP/ca.crt"
printf 'user = "admin:%s"\n' "$(cat "$TMP/pw")" > "$TMP/admin.cfg"
CURL=(curl -sS --cacert "$TMP/ca.crt" --connect-timeout 5 --max-time 20)
api() {  # api <METHOD> <path> [json-body]
  local extra=()
  [ -n "${3:-}" ] && extra=(-H 'Content-Type: application/json' --data-binary "$3")
  "${CURL[@]}" -K "$TMP/admin.cfg" -o "$TMP/body" -w '%{http_code}' -X "$1" "${extra[@]}" "$URL$2" || printf '000'
}
anon() { "${CURL[@]}" -o "$TMP/body" -w '%{http_code}' "$URL$1" || printf '000'; }

ready_pods() { ocn get pods -l "$SEL" -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | grep -c . || true; }
wait_ready() {  # wait_ready <seconds>
  local end=$((SECONDS + $1))
  while [ $SECONDS -lt $end ]; do
    [ "$(ready_pods)" -eq "$REPLICAS" ] && [ "$(ocn get pods -l "$SEL" --no-headers | wc -l)" -eq "$REPLICAS" ] \
      && [ "$(anon /api/health)" = 200 ] && return 0
    sleep 5
  done
  return 1
}
zone_of() { oc get node "$1" -o go-template="{{index .metadata.labels \"$ZONE_LABEL\"}}"; }
is_data_zone() { local z; for z in "${DATA_ZONE_LIST[@]}"; do [ "$1" = "$z" ] && return 0; done; return 1; }

# Background load: counts non-200 answers over <seconds> (fresh connection each time).
load_start() {
  : > "$TMP/load"
  ( end=$((SECONDS + $1))
    while [ $SECONDS -lt $end ]; do
      "${CURL[@]}" -o /dev/null -w '%{http_code}\n' --max-time 5 "$URL/api/dashboards/uid/acc-shared" >> "$TMP/load" 2>/dev/null || echo 000 >> "$TMP/load"
      sleep 0.2
    done ) &
  LOAD_PID=$!
}
load_result() { wait "$LOAD_PID" || true; LOAD_OK=$(grep -c '^200$' "$TMP/load" || true); LOAD_FAIL=$(grep -vc '^200$' "$TMP/load" || true); }

echo "Acceptance test - $(date -u +%Y-%m-%dT%H:%MZ) - $REPLICAS replicas, data zones: ${DATA_ZONE_LIST[*]}" | tee "$REPORT"
wait_ready 300 || warn "Grafana not fully ready before the tests"

# A01
n="$(ready_pods)"
[ "$n" -eq "$REPLICAS" ] && result A01 PASS "$n/$REPLICAS replicas ready" || result A01 FAIL "$n/$REPLICAS replicas ready"

# A02
declare -A per_zone=(); outside=0
while read -r pod node; do
  [ -n "$pod" ] || continue
  z="$(zone_of "$node")"; per_zone[$z]=$(( ${per_zone[$z]:-0} + 1 ))
  is_data_zone "$z" || outside=$((outside + 1))
done < <(ocn get pods -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}')
pgz="$(zone_of "$(ocn get pod grafana-postgresql-0 -o jsonpath='{.spec.nodeName}')")"
dist="$(for z in "${!per_zone[@]}"; do printf '%s=%s ' "$z" "${per_zone[$z]}"; done)"
half=$((REPLICAS / 2))
if [ "$outside" -gt 0 ] || ! is_data_zone "$pgz"; then result A02 FAIL "pods outside the data zones ($dist; PostgreSQL in $pgz)"
elif [ "${per_zone[${DATA_ZONE_LIST[0]}]:-0}" -eq "$half" ] && [ "${per_zone[${DATA_ZONE_LIST[1]}]:-0}" -eq "$half" ]; then result A02 PASS "$dist; PostgreSQL in a data zone"
else result A02 WARN "uneven split: $dist"; fi

# A03
api GET /api/admin/settings >/dev/null
dbtype="$(grep -o '"type":"[a-z0-9]*"' "$TMP/body" | head -n 1 | cut -d'"' -f4)"
pvcs="$(ocn get pvc -l "$SEL" --no-headers 2>/dev/null | wc -l)"
[ "$dbtype" = postgres ] && [ "$pvcs" -eq 0 ] && result A03 PASS "database=postgres, no Grafana PVC" || result A03 FAIL "database=$dbtype, Grafana PVCs=$pvcs"

# A04 (metrics read inside each pod's own view through the service, several samples)
members=""
for _ in 1 2 3 4 5 6 7 8; do
  "${CURL[@]}" -K "$TMP/admin.cfg" "$URL/metrics" -o "$TMP/metrics" || true
  m="$(grep -E '^[a-z_]*cluster_members(\{[^}]*\})? ' "$TMP/metrics" | awk '{print int($2)}' | head -n 1 || true)"
  members="$members ${m:-?}"
done
bad="$(for v in $members; do [ "$v" = "$REPLICAS" ] || echo "$v"; done | grep -c . || true)"
[ "$bad" -eq 0 ] && result A04 PASS "alerting cluster members seen:$members" || result A04 FAIL "alerting cluster members seen:$members (expected $REPLICAS)"

# A05 route TLS and redirect
code_http="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "http://$ROUTE_HOST/" || echo 000)"
code_https="$(anon /api/health)"
case "$code_http" in 30[1278]\ https://*) redir=yes ;; *) redir=no ;; esac
[ "$code_https" = 200 ] && [ "$redir" = yes ] && result A05 PASS "HTTPS 200 with a trusted certificate, HTTP redirected" \
  || result A05 FAIL "HTTPS=$code_https, HTTP=$code_http"

# A06 OpenShift login offered and redirecting to the OAuth server
anon /api/frontend/settings >/dev/null
offered="$(grep -c '"generic_oauth"' "$TMP/body" || true)"
loc="$("${CURL[@]}" -o /dev/null -w '%{redirect_url}' "$URL/login/generic_oauth" || true)"
case "$loc" in "https://$OAUTH_HOST/oauth/authorize"*client_id=grafana*) to_oauth=yes ;; *) to_oauth=no ;; esac
[ "$offered" -gt 0 ] && [ "$to_oauth" = yes ] && result A06 PASS "OpenShift login offered, redirects to the OAuth server with client_id=grafana (complete one login by hand to check group mapping)" \
  || result A06 FAIL "login offered=$offered, redirect=$loc"

# A07 test content, anonymous view, consistency
for f in acc-shared-f acc-restricted-f; do api DELETE "/api/folders/$f?forceDeleteRules=true" >/dev/null; done
c1="$(api POST /api/folders '{"uid":"acc-shared-f","title":"acc shared (acceptance test)"}')"
c2="$(api POST /api/folders '{"uid":"acc-restricted-f","title":"acc restricted (acceptance test)"}')"
c3="$(api POST /api/folders/acc-restricted-f/permissions '{"items":[{"role":"Editor","permission":2}]}')"
c4="$(api POST /api/dashboards/db '{"folderUid":"acc-shared-f","overwrite":true,"dashboard":{"uid":"acc-shared","title":"acc shared dashboard","tags":["acc"],"panels":[],"schemaVersion":41}}')"
c5="$(api POST /api/dashboards/db '{"folderUid":"acc-restricted-f","overwrite":true,"dashboard":{"uid":"acc-restricted","title":"acc restricted dashboard","tags":["acc"],"panels":[],"schemaVersion":41}}')"
sh="$(anon /api/dashboards/uid/acc-shared)"; rs="$(anon /api/dashboards/uid/acc-restricted)"
same=0; for _ in $(seq 1 30); do [ "$(api GET /api/dashboards/uid/acc-shared)" = 200 ] && same=$((same + 1)); done
if [ "$c1$c2$c3$c4$c5" = 200200200200200 ] && [ "$sh" = 200 ] && [ "$rs" != 200 ] && [ "$same" -eq 30 ]; then
  result A07 PASS "anonymous: shared=$sh restricted=$rs; 30/30 requests found the dashboard"
else
  result A07 FAIL "create=$c1/$c2/$c3/$c4/$c5 anonymous shared=$sh restricted=$rs consistent=$same/30"
fi

content_ok() { [ "$(api GET /api/dashboards/uid/acc-shared)" = 200 ] && [ "$(api GET /api/dashboards/uid/acc-restricted)" = 200 ] && [ "$(anon /api/dashboards/uid/acc-restricted)" != 200 ]; }

# A08 delete all pods
ocn delete pod -l "$SEL" --wait=false >/dev/null; sleep 10
wait_ready 600 && content_ok && result A08 PASS "all pods replaced, content and permissions kept" || result A08 FAIL "pods not ready or content missing after deleting all pods"

# A09 one pod under load
load_start 60; sleep 10
ocn delete pod "$(ocn get pods -l "$SEL" -o jsonpath='{.items[0].metadata.name}')" --wait=false >/dev/null
load_result; wait_ready 600 || true
if [ "$LOAD_FAIL" -eq 0 ]; then result A09 PASS "requests ok=$LOAD_OK failed=0"
elif [ "$LOAD_FAIL" -le 3 ]; then result A09 WARN "requests ok=$LOAD_OK failed=$LOAD_FAIL"
else result A09 FAIL "requests ok=$LOAD_OK failed=$LOAD_FAIL"; fi

# A10 all pods of one data zone at once (the zone without PostgreSQL)
lost="${DATA_ZONE_LIST[0]}"; [ "$lost" = "$pgz" ] && lost="${DATA_ZONE_LIST[1]}"
victims="$(ocn get pods -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' \
  | while read -r p nd; do [ "$(zone_of "$nd")" = "$lost" ] && echo "$p"; done)"
load_start 90; sleep 10
# shellcheck disable=SC2086
[ -n "$victims" ] && ocn delete pod $victims --wait=false >/dev/null
load_result; wait_ready 600 || true
if [ "$LOAD_FAIL" -eq 0 ]; then result A10 PASS "killed $(echo "$victims" | grep -c .) pod(s) of $lost; requests ok=$LOAD_OK failed=0"
elif [ "$LOAD_FAIL" -le 3 ]; then result A10 WARN "killed the pods of $lost; requests ok=$LOAD_OK failed=$LOAD_FAIL"
else result A10 FAIL "killed the pods of $lost; requests ok=$LOAD_OK failed=$LOAD_FAIL"; fi

# A11 NetworkPolicy on PostgreSQL (probe pods use the deployed PostgreSQL image)
pgimage="$(ocn get statefulset grafana-postgresql -o jsonpath='{.spec.template.spec.containers[0].image}')"
probe() {  # probe <name> <label-line or empty>
  ocn delete pod "$1" --ignore-not-found --wait=true >/dev/null
  zl="$(printf '"%s",' "${DATA_ZONE_LIST[@]}")"
  cat <<EOF | ocn apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels:
    app.kubernetes.io/name: acc-probe
$2
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: "$ZONE_LABEL", operator: In, values: [${zl%,}]}
  containers:
    - name: probe
      image: $pgimage
      command: ["pg_isready", "-h", "grafana-postgresql", "-p", "5432", "-t", "8"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
EOF
  local end=$((SECONDS + 180)) ph=""
  while [ $SECONDS -lt $end ]; do
    ph="$(ocn get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 3
  done
  ocn logs "$1" 2>/dev/null || true
  ocn delete pod "$1" --ignore-not-found --wait=false >/dev/null
}
denied="$(probe acc-probe-unlabelled "")"
allowed="$(probe acc-probe-labelled '    grafana-db-client: "true"')"
if echo "$allowed" | grep -q 'accepting connections' && ! echo "$denied" | grep -q 'accepting connections'; then
  result A11 PASS "unlabelled: '$denied' / labelled: '$allowed'"
else result A11 FAIL "unlabelled: '$denied' / labelled: '$allowed'"; fi

# A12 backup now
job="acc-backup-$(date +%Y%m%d%H%M%S)"
ocn create job "$job" --from=cronjob/grafana-db-backup >/dev/null
if ocn wait --for=condition=complete "job/$job" --timeout=15m >/dev/null 2>&1 && ocn logs "job/$job" | grep -q 'backup written'; then
  result A12 PASS "backup job succeeded: $(ocn logs "job/$job" | grep 'backup written' | sed 's#.*/##')"
else result A12 FAIL "backup job failed: $(ocn logs "job/$job" 2>&1 | tail -n 3 | tr '\n' ' ')"; fi
ocn delete job "$job" --ignore-not-found >/dev/null

# A13 restore (disruptive, optional)
if [ "$WITH_RESTORE" = 1 ]; then
  api DELETE /api/dashboards/uid/acc-shared >/dev/null
  gone="$(api GET /api/dashboards/uid/acc-shared)"
  "$REPO_ROOT/scripts/db-restore.sh" --file latest --yes ${ENV_ARG:+--env "$ENV_ARG"} >/dev/null 2>&1 || true
  wait_ready 600 || true
  back="$(api GET /api/dashboards/uid/acc-shared)"
  [ "$gone" != 200 ] && [ "$back" = 200 ] && result A13 PASS "dashboard deleted, database restored, dashboard back" \
    || result A13 FAIL "after delete=$gone, after restore=$back"
else
  echo "SKIP A13 restore (use --with-restore on non-production)" | tee -a "$REPORT"
fi

# A14 nothing of the namespace outside the data zones
outside_pods="$(ocn get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' \
  | while read -r p nd; do [ -n "$nd" ] && ! is_data_zone "$(zone_of "$nd")" && echo "$p"; done || true)"
[ -z "$outside_pods" ] && result A14 PASS "no pod of $NAMESPACE outside the data zones" || result A14 FAIL "outside the data zones: $outside_pods"

# Cleanup of the test content
for f in acc-shared-f acc-restricted-f; do api DELETE "/api/folders/$f?forceDeleteRules=true" >/dev/null; done

echo "PASS $PASS  WARN $WARN  FAIL $FAIL" | tee -a "$REPORT"
log "Report: $REPORT (no secret inside)"
[ "$FAIL" -eq 0 ]
