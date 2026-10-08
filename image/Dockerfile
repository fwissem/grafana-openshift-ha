# Grafana image used by this deployment: the official distroless image plus the
# plugins listed in values/plugins.lock, so no pod downloads anything at start.
#
# scripts/build-image.sh unpacks image/plugins/*.zip into the build context and
# builds this file in the cluster (OpenShift binary build). The local test
# builds it with Podman. The base image below is the single place where the
# Grafana version is set for the image.
ARG BASE_IMAGE=docker.io/grafana/grafana:13.2.3-distroless
FROM ${BASE_IMAGE}

# Outside /var/lib/grafana, which is an emptyDir in the pod and would hide them.
# grafana.ini [paths] plugins points here (values/values.yaml). Mode 0755 so the
# arbitrary UID that OpenShift assigns can read them.
COPY --chmod=0755 plugins/ /opt/grafana/plugins/
