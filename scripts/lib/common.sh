#!/usr/bin/env bash
# common.sh - helpers shared by the deployment scripts (sourced, not executed).
#
# Targets RHEL 8/9 bash with oc and helm only. No secret is ever printed,
# passed on a command line (visible in `ps`) or written outside a private
# temporary directory that is removed on exit.

# shellcheck disable=SC2034  # variables are used by the scripts that source this file

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DIR="$REPO_ROOT/local"
RENDER_DIR="$LOCAL_DIR/render"

if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_OFF=''
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLD" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s  ERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Private temp dir for secret material, removed on exit.
# Call init_secure_tmp in the MAIN shell (not inside $(...): a subshell would
# remove the directory as soon as it exits), then use "$SECURE_TMP".
SECURE_TMP=""
init_secure_tmp() {
  if [ -z "$SECURE_TMP" ]; then
    SECURE_TMP="$(umask 077 && mktemp -d)" || die "cannot create a temporary directory"
    trap 'rm -rf "$SECURE_TMP"' EXIT
  fi
}

# Random password: letters and digits only (A-Z a-z 0-9), default 24 chars.
# Reads a bounded amount of /dev/urandom (no SIGPIPE under pipefail).
gen_password() {
  local len="${1:-24}" pw=""
  while [ "${#pw}" -lt "$len" ]; do
    pw="$pw$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${pw:0:$len}"
}

need_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' not found in PATH"
  done
}

# Refuse to run scripts saved with Windows line endings.
check_line_endings() {
  local f bad=0
  while IFS= read -r -d '' f; do
    if grep -q $'\r' "$f"; then warn "Windows line endings in $f"; bad=1; fi
  done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/tests/openshift" -type f -name '*.sh' -print0 2>/dev/null)
  [ "$bad" -eq 0 ] || die "convert the files to LF (clone the repository with git on Linux)"
}

# Load the private deployment settings.
load_env() {
  local env_file="${1:-$LOCAL_DIR/deploy.env}"
  [ -r "$env_file" ] || die "settings file not found: $env_file (copy deploy.env.example to local/deploy.env)"
  grep -q $'\r' "$env_file" && die "$env_file has Windows line endings"
  # shellcheck disable=SC1090
  . "$env_file"
  local v
  for v in EXPECTED_API_SERVER NAMESPACE RELEASE ZONE_LABEL DATA_ZONES REPLICAS \
           STORAGE_CLASS BACKUP_STORAGE_CLASS DB_VOLUME_SIZE BACKUP_VOLUME_SIZE \
           POSTGRES_IMAGE ROUTE_HOST OAUTH_HOST GRAFANA_ADMIN_GROUP GRAFANA_EDITOR_GROUP \
           UWM_ENABLED CHART_VERSION; do
    [ -n "${!v:-}" ] || die "$v is empty in $env_file"
  done
  GRAFANA_IMAGE_REGISTRY="${GRAFANA_IMAGE_REGISTRY:-}"
  read -r -a DATA_ZONE_LIST <<< "$DATA_ZONES"
  [ "${#DATA_ZONE_LIST[@]}" -eq 2 ] || die "DATA_ZONES must list exactly the two data zones (got: $DATA_ZONES)"
  ENV_FILE="$env_file"
}

# Make sure we talk to the intended cluster.
check_cluster() {
  local server
  server="$(oc whoami --show-server 2>/dev/null)" || die "not logged in (oc login, or export KUBECONFIG)"
  [ "$server" = "$EXPECTED_API_SERVER" ] || die "logged in to $server, but EXPECTED_API_SERVER is $EXPECTED_API_SERVER"
  ok "cluster: $server as $(oc whoami 2>/dev/null)"
}

# Ask before a change, unless --yes was given.
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "aborted"
}

ocn() { oc -n "$NAMESPACE" "$@"; }

# Create or replace a generic secret from files in a private temp dir
# (values never appear on a command line). Usage: apply_secret name key=file...
apply_secret() {
  local name="$1"; shift
  local args=() kv
  for kv in "$@"; do args+=("--from-file=$kv"); done
  ocn create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | ocn apply -f - >/dev/null \
    || die "could not create secret $name"
  ocn label secret "$name" app.kubernetes.io/part-of=grafana --overwrite >/dev/null 2>&1 || true
}
