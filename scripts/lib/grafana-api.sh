#!/usr/bin/env bash
# grafana-api.sh - minimal Grafana HTTP API client for bash (sourced).
#
# Credentials never appear on a command line: they go into a curl config file
# in a private temporary directory, removed on exit.
#
# Authentication (first match wins):
#   GRAFANA_TOKEN                 service account token (recommended)
#   GRAFANA_USER + prompt         basic auth, the password is read without echo
#
# TLS: GRAFANA_CACERT=<file> to trust an internal CA, or GRAFANA_INSECURE=1
# (not recommended) to skip verification.

# shellcheck disable=SC2034

GAPI_URL=""
GAPI_CFG=""

# gapi_init <url>
gapi_init() {
  GAPI_URL="${1%/}"
  init_secure_tmp; local tmp="$SECURE_TMP"
  GAPI_CFG="$tmp/curl-$$.cfg"
  : > "$GAPI_CFG"
  if [ -n "${GRAFANA_TOKEN:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$GRAFANA_TOKEN" >> "$GAPI_CFG"
  else
    local user="${GRAFANA_USER:-admin}" pass
    read -r -s -p "Password for $user on $GAPI_URL: " pass; echo
    [ -n "$pass" ] || die "empty password"
    printf 'user = "%s:%s"\n' "$user" "$pass" >> "$GAPI_CFG"
  fi
  if [ -n "${GRAFANA_CACERT:-}" ]; then
    [ -r "$GRAFANA_CACERT" ] || die "GRAFANA_CACERT not readable: $GRAFANA_CACERT"
    printf 'cacert = "%s"\n' "$GRAFANA_CACERT" >> "$GAPI_CFG"
  elif [ "${GRAFANA_INSECURE:-0}" = "1" ]; then
    printf 'insecure\n' >> "$GAPI_CFG"
  fi
  printf 'silent\nshow-error\nconnect-timeout = 10\nmax-time = 120\n' >> "$GAPI_CFG"
  if [ -n "${GRAFANA_ORG_ID:-}" ]; then
    printf 'header = "X-Grafana-Org-Id: %s"\n' "$GRAFANA_ORG_ID" >> "$GAPI_CFG"
  fi
  local code
  code="$(gapi GET /api/user /dev/null)" || true
  [ "$code" = 200 ] || die "cannot authenticate to $GAPI_URL (HTTP $code)"
}

# gapi <METHOD> <path> <outfile> [json-body-file] [extra-header]
# Prints the HTTP status code; the response body goes to <outfile>.
gapi() {
  local method="$1" path="$2" out="$3" body="${4:-}" extra="${5:-}"
  local args=(-K "$GAPI_CFG" -X "$method" -o "$out" -w '%{http_code}' -H 'Accept: application/json')
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data-binary "@$body"); fi
  if [ -n "$extra" ]; then args+=(-H "$extra"); fi
  curl "${args[@]}" "$GAPI_URL$path" || printf '000'
}
