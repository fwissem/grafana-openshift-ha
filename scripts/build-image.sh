#!/usr/bin/env bash
# build-image.sh - build the Grafana image with its plugins in the cluster.
#
# The cluster cannot download plugins, so they are baked into the image: the
# official Grafana image plus the archives of image/plugins/ (checked against
# values/plugins.lock). The build runs in the target namespace as an OpenShift
# binary build and pushes to the internal registry, so it needs no registry
# account and no Internet access from the deployment machine.
#
#   --check   show the image tag and what would be created (no change)
#   --apply   create or update the ImageStreams and BuildConfig, then build
#
# The tag is derived from image/Dockerfile and values/plugins.lock, so it only
# changes when they change; an existing tag is not rebuilt. install.sh uses the
# image by digest.
#
# Usage:
#   scripts/build-image.sh --check [--env local/deploy.env]
#   scripts/build-image.sh --apply [--env local/deploy.env] [--yes]

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=""; ENV_ARG=""; ASSUME_YES=0
# shellcheck disable=SC2034  # ASSUME_YES is read by confirm() in lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,19p' "$0"; exit 2; }

need_tools oc sha256sum
command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || die "need unzip or python3 to unpack the plugins"
check_line_endings
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

# ------------------------------------------------------------------------------------
# Inputs and plan
# ------------------------------------------------------------------------------------
verify_plugin_archives > /dev/null
while read -r pid pver; do ok "plugin $pid $pver (SHA-256 checked)"; done < <(verify_plugin_archives)
BASE="$(grafana_base_image)"
[ -n "$BASE" ] || die "no ARG BASE_IMAGE in image/Dockerfile"
BASE_TAG="${BASE##*:}"
IMPORT_FROM="$BASE"
if [ -n "$GRAFANA_IMAGE_REGISTRY" ]; then IMPORT_FROM="${GRAFANA_IMAGE_REGISTRY%/}/${BASE#docker.io/}"; fi
TAG="$(grafana_image_tag)"
log "base image: $IMPORT_FROM"
log "image to build: imagestream grafana:$TAG in namespace $NAMESPACE"

oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE does not exist"
build_api="$(oc api-resources --api-group=build.openshift.io -o name 2>/dev/null || true)"
case "$build_api" in
  *buildconfigs*) ok "Build API available" ;;
  *) die "the Build API is not available on this cluster (Build capability disabled?)" ;;
esac
state="$(oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
case "$state" in
  Managed) ok "internal image registry: Managed" ;;
  "") warn "cannot read the image registry configuration (no permission?): assuming it is available" ;;
  *) die "the internal image registry is '$state', not Managed: ask the platform team to enable it" ;;
esac
for r in buildconfigs.build.openshift.io imagestreams.image.openshift.io builds.build.openshift.io/docker; do
  [ "$(ocn auth can-i create "$r" 2>/dev/null)" = yes ] || die "you cannot create $r in $NAMESPACE"
done
ok "rights to build in $NAMESPACE"

if exists imagestreamtag "grafana:$TAG"; then
  ok "grafana:$TAG already exists: nothing to build"
  exit 0
fi
log "Planned changes in namespace $NAMESPACE:"
echo "    - import $IMPORT_FROM as imagestream grafana-base:$BASE_TAG"
echo "    - create/update imagestream grafana and buildconfig grafana-image"
echo "    - build grafana:$TAG (build pod in data zone ${DATA_ZONE_LIST[0]})"
if [ "$MODE" = check ]; then
  log "--check: nothing changed. Run with --apply to build."
  exit 0
fi
confirm "Build the Grafana image grafana:$TAG?"

# ------------------------------------------------------------------------------------
# Build context: Dockerfile + unpacked plugins, readable by any user
# ------------------------------------------------------------------------------------
CTX="$LOCAL_DIR/build/grafana-image"
rm -rf "$CTX"; mkdir -p "$CTX/plugins"
cp "$IMAGE_DIR/Dockerfile" "$CTX/"
while read -r pid pver; do
  zip="$IMAGE_DIR/plugins/$pid-$pver.zip"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip" -d "$CTX/plugins"
  else
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$CTX/plugins"
  fi
  [ -r "$CTX/plugins/$pid/plugin.json" ] || die "$zip does not contain $pid/plugin.json"
done < <(verify_plugin_archives)
chmod -R a+rX "$CTX"
ok "build context ready in $CTX"

# ------------------------------------------------------------------------------------
# ImageStreams and BuildConfig (the build pod runs in a data zone, never the quorum zone)
# ------------------------------------------------------------------------------------
# reference-policy=local: the build pulls the base image through the internal
# registry, which applies the cluster's proxy and mirror settings.
ocn import-image "grafana-base:$BASE_TAG" --from="$IMPORT_FROM" --confirm \
    --reference-policy=local --scheduled=false >/dev/null \
  || die "could not import $IMPORT_FROM (check that the cluster can pull it)"
ok "imported $IMPORT_FROM as grafana-base:$BASE_TAG"

cat <<EOF | ocn apply -f - >/dev/null
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: grafana
  labels:
    app.kubernetes.io/part-of: grafana
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: grafana-image
  labels:
    app.kubernetes.io/part-of: grafana
spec:
  runPolicy: Serial
  successfulBuildsHistoryLimit: 2
  failedBuildsHistoryLimit: 2
  nodeSelector:
    "$ZONE_LABEL": "${DATA_ZONE_LIST[0]}"
  source:
    type: Binary
  strategy:
    type: Docker
    dockerStrategy:
      from:
        kind: ImageStreamTag
        name: "grafana-base:$BASE_TAG"
  output:
    to:
      kind: ImageStreamTag
      name: "grafana:$TAG"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
EOF
ok "imagestream grafana and buildconfig grafana-image applied"

log "building (logs follow)"
ocn start-build grafana-image --from-dir="$CTX" --follow --wait \
  || die "build failed: oc -n $NAMESPACE get builds; oc -n $NAMESPACE logs build/<name>"
ref="$(ocn get imagestreamtag "grafana:$TAG" -o jsonpath='{.image.dockerImageReference}')"
ok "built $ref"
log "Next: scripts/install.sh --check"
