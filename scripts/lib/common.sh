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
           UWM_ENABLED CHART_VERSION PLUGINS_STORAGE_CLASS PLUGINS_VOLUME_SIZE; do
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
  read -r -p "$1 [y/N] " answer || die "no answer (non-interactive run? add --yes)"
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "aborted"
}

ocn() { oc -n "$NAMESPACE" "$@"; }

# exists <kind> <name>: 0 if the object exists, 1 if it does not. Any other error
# (no permission, API unreachable, expired login) stops the script, so a failed
# read is never mistaken for "absent" and a kept secret is never regenerated.
exists() {
  local out
  out="$(ocn get "$1" "$2" -o name 2>&1)" && return 0
  case "$out" in
    *NotFound*|*"not found"*) return 1 ;;
    *) die "cannot read $1/$2: $out" ;;
  esac
}

# wait_job <job> <seconds>: returns 0 when the Job completes, 1 as soon as it
# fails, 2 on timeout. (`oc wait --for=condition=complete` would keep waiting
# until the timeout on a failed Job.)
wait_job() {
  local job="$1" end=$((SECONDS + $2)) c
  while [ "$SECONDS" -lt "$end" ]; do
    c="$(ocn get job "$job" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || true)"
    case "$c" in
      *Complete*) return 0 ;;
      *Failed*) return 1 ;;
    esac
    sleep 5
  done
  return 2
}

# Need read access to nodes for the zone checks.
need_node_read() {
  [ "$(oc auth can-i list nodes 2>/dev/null)" = yes ] \
    || die "your account cannot list nodes; the zone checks need it (ask for a cluster-reader role)"
}

# Create a generic secret from files in a private temp dir (values never appear
# on a command line). Fails if the secret already exists, so a password or key
# that must never change cannot be overwritten. Usage: create_secret name key=file...
create_secret() {
  local name="$1"; shift
  local args=() kv
  for kv in "$@"; do args+=("--from-file=$kv"); done
  ocn create secret generic "$name" "${args[@]}" >/dev/null || die "could not create secret $name (does it already exist?)"
  ocn label secret "$name" app.kubernetes.io/part-of=grafana --overwrite >/dev/null 2>&1 || true
}

# Create or replace a generic secret, same rules for the values.
# Usage: apply_secret name key=file...
apply_secret() {
  local name="$1"; shift
  local args=() kv
  for kv in "$@"; do args+=("--from-file=$kv"); done
  ocn create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | ocn apply -f - >/dev/null \
    || die "could not create secret $name"
  ocn label secret "$name" app.kubernetes.io/part-of=grafana --overwrite >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Plugins (plugins/*.zip, listed in values/plugins.lock), served to the Grafana
# pods from the volume grafana-plugins (scripts/load-plugins.sh).
# ------------------------------------------------------------------------------
PLUGINS_DIR="$REPO_ROOT/plugins"
PLUGINS_LOCK="$REPO_ROOT/values/plugins.lock"

# Identifies a plugin set: changes whenever values/plugins.lock changes.
plugins_hash() { sha256sum "$PLUGINS_LOCK" | cut -c1-12; }

# Check every archive of plugins.lock against its SHA-256. Prints "id version" lines.
verify_plugin_archives() {
  local pid pver psum _rest f got n=0
  while read -r pid pver psum _rest; do
    case "$pid" in ''|'#'*) continue ;; esac
    f="$PLUGINS_DIR/$pid-$pver.zip"
    [ -r "$f" ] || die "missing $f (listed in values/plugins.lock)"
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$got" = "$psum" ] || die "$f: SHA-256 is $got, values/plugins.lock expects $psum"
    echo "$pid $pver"
    n=$((n + 1))
  done < "$PLUGINS_LOCK"
  [ "$n" -gt 0 ] || die "no plugin listed in $PLUGINS_LOCK"
}
