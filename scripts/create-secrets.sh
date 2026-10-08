#!/usr/bin/env bash
# create-secrets.sh - create the Secrets, OAuth client and CA bundle Grafana needs.
#
# Read-only by default (--check). Nothing is changed without --apply.
# Existing secrets are KEPT: the database password and the secret key must never
# change once Grafana has started (PostgreSQL is initialised with the first one,
# datasource secrets are encrypted with the second one).
#
#   grafana-admin              admin-user, admin-password   (break-glass local admin)
#   grafana-db                 username, password, database (PostgreSQL + Grafana)
#   grafana-secret-key         secret-key                   (same on every replica)
#   grafana-oauth              client-secret                (OpenShift OAuth client)
#   grafana-datasource-tokens  one key per DS_TOKEN_*       (from local/datasource-tokens.env)
#   ConfigMap grafana-oauth-ca ca.crt                       (API + ingress CAs, for OAuth calls)
#   OAuthClient grafana        cluster-scoped               (needs cluster-admin)
#
# Passwords: 24 random letters and digits. They are never printed. To read one:
#   oc -n <ns> get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
#
# Usage:
#   scripts/create-secrets.sh --check  [--env local/deploy.env]
#   scripts/create-secrets.sh --apply  [--env local/deploy.env] [--yes]
#   scripts/create-secrets.sh --apply --refresh-tokens   # re-read local/datasource-tokens.env
#   scripts/create-secrets.sh --apply --refresh-ca       # rebuild the CA bundle

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

MODE=""; ENV_ARG=""; ASSUME_YES=0; REFRESH_TOKENS=0; REFRESH_CA=0
# shellcheck disable=SC2034  # ASSUME_YES is read by confirm() in lib/common.sh
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --apply) MODE=apply; shift ;;
    --env) ENV_ARG="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --refresh-tokens) REFRESH_TOKENS=1; shift ;;
    --refresh-ca) REFRESH_CA=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,29p' "$0"; exit 2; }

need_tools oc base64 head tr
check_line_endings
load_env "${ENV_ARG:-$LOCAL_DIR/deploy.env}"
check_cluster

oc get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "namespace $NAMESPACE does not exist (ask for it, or: oc new-project $NAMESPACE)"

exists_secret() { exists secret "$1"; }
exists_cm()     { exists configmap "$1"; }

TOKENS_FILE="$LOCAL_DIR/datasource-tokens.env"
REDIRECT_URI="https://$ROUTE_HOST/login/generic_oauth"

# ------------------------------------------------------------------------------------
# Plan
# ------------------------------------------------------------------------------------
plan=()
for s in grafana-admin grafana-db grafana-secret-key grafana-oauth; do
  if exists_secret "$s"; then ok "secret $s exists (kept)"; else plan+=("create secret $s"); fi
done
if [ -r "$TOKENS_FILE" ]; then
  if ! exists_secret grafana-datasource-tokens || [ "$REFRESH_TOKENS" = 1 ]; then
    plan+=("create/replace secret grafana-datasource-tokens from $TOKENS_FILE ($(grep -cE '^[A-Z0-9_]+=' "$TOKENS_FILE" || true) keys)")
  else
    ok "secret grafana-datasource-tokens exists (kept; --refresh-tokens to reload)"
  fi
else
  warn "$TOKENS_FILE not found: no datasource token secret (fine if datasources need none)"
fi
if ! exists_cm grafana-oauth-ca || [ "$REFRESH_CA" = 1 ]; then
  plan+=("create/replace ConfigMap grafana-oauth-ca (API CA + ingress CA)")
else
  ok "ConfigMap grafana-oauth-ca exists (kept; --refresh-ca to rebuild)"
fi
if oc get oauthclient grafana -o name >/dev/null 2>&1; then
  current_redirects="$(oc get oauthclient grafana -o jsonpath='{.redirectURIs}')"
  case "$current_redirects" in
    *"$REDIRECT_URI"*) ok "OAuthClient grafana exists with redirect $REDIRECT_URI" ;;
    *) plan+=("update OAuthClient grafana redirect URI to $REDIRECT_URI") ;;
  esac
  exists_secret grafana-oauth || plan+=("set a new secret on OAuthClient grafana (grafana-oauth missing)")
else
  plan+=("create OAuthClient grafana (cluster-scoped, redirect $REDIRECT_URI)")
fi

if [ "${#plan[@]}" -eq 0 ]; then
  ok "nothing to do"
  exit 0
fi
log "Planned changes in namespace $NAMESPACE:"
for p in "${plan[@]}"; do printf '    - %s\n' "$p"; done

if [ "$MODE" = check ]; then
  log "--check: nothing changed. Run with --apply to make these changes."
  exit 0
fi
confirm "Apply these changes?"

init_secure_tmp; TMP="$SECURE_TMP"

# ------------------------------------------------------------------------------------
# Secrets (only when absent)
# ------------------------------------------------------------------------------------
if ! exists_secret grafana-admin; then
  printf 'admin' > "$TMP/admin-user"
  gen_password 24 > "$TMP/admin-password"
  create_secret grafana-admin "admin-user=$TMP/admin-user" "admin-password=$TMP/admin-password"
  ok "secret grafana-admin created"
fi
if ! exists_secret grafana-db; then
  printf 'grafana' > "$TMP/db-user"
  gen_password 24 > "$TMP/db-password"
  printf 'grafana' > "$TMP/db-name"
  create_secret grafana-db "username=$TMP/db-user" "password=$TMP/db-password" "database=$TMP/db-name"
  ok "secret grafana-db created"
fi
if ! exists_secret grafana-secret-key; then
  gen_password 40 > "$TMP/secret-key"
  create_secret grafana-secret-key "secret-key=$TMP/secret-key"
  ok "secret grafana-secret-key created"
fi

# Datasource tokens: KEY=VALUE lines, keys like DS_TOKEN_CLUSTER_A.
if [ -r "$TOKENS_FILE" ] && { ! exists_secret grafana-datasource-tokens || [ "$REFRESH_TOKENS" = 1 ]; }; then
  grep -q $'\r' "$TOKENS_FILE" && die "$TOKENS_FILE has Windows line endings"
  bad="$(grep -vE '^(#.*|[[:space:]]*|[A-Z0-9_]+=.+)$' "$TOKENS_FILE" || true)"
  [ -z "$bad" ] || die "$TOKENS_FILE: lines must be KEY=VALUE with KEY in [A-Z0-9_]"
  ocn create secret generic grafana-datasource-tokens --from-env-file="$TOKENS_FILE" \
      --dry-run=client -o yaml | ocn apply -f - >/dev/null
  ok "secret grafana-datasource-tokens created/replaced (run scripts/install.sh --apply to roll the pods)"
fi

# ------------------------------------------------------------------------------------
# CA bundle for the OAuth calls made by Grafana: in-cluster API (users/~) and the
# OAuth route (token exchange) signed by the ingress CA.
# ------------------------------------------------------------------------------------
if ! exists_cm grafana-oauth-ca || [ "$REFRESH_CA" = 1 ]; then
  : > "$TMP/ca.crt"
  if ocn get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' >> "$TMP/ca.crt" 2>/dev/null; then
    printf '\n' >> "$TMP/ca.crt"; ok "added the cluster API CA (kube-root-ca.crt)"
  else
    warn "could not read kube-root-ca.crt in $NAMESPACE"
  fi
  if oc -n openshift-config-managed get configmap default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' >> "$TMP/ca.crt" 2>/dev/null; then
    printf '\n' >> "$TMP/ca.crt"; ok "added the ingress CA (default-ingress-cert)"
  else
    warn "could not read openshift-config-managed/default-ingress-cert (custom router certificate?)"
  fi
  if [ -n "${EXTRA_CA_FILE:-}" ]; then
    [ -r "$EXTRA_CA_FILE" ] || die "EXTRA_CA_FILE not readable: $EXTRA_CA_FILE"
    cat "$EXTRA_CA_FILE" >> "$TMP/ca.crt"; ok "added $EXTRA_CA_FILE"
  fi
  grep -q 'BEGIN CERTIFICATE' "$TMP/ca.crt" || die "CA bundle is empty; set EXTRA_CA_FILE in deploy.env"
  ocn create configmap grafana-oauth-ca --from-file=ca.crt="$TMP/ca.crt" --dry-run=client -o yaml | ocn apply -f - >/dev/null
  ok "ConfigMap grafana-oauth-ca created/replaced"
fi

# ------------------------------------------------------------------------------------
# OAuth client (cluster-scoped). Needs cluster-admin; otherwise a manifest is
# written for an administrator (it contains the client secret: delete it after use).
# ------------------------------------------------------------------------------------
need_client_secret=0
if ! exists_secret grafana-oauth; then
  gen_password 40 > "$TMP/client-secret"
  need_client_secret=1
else
  ocn get secret grafana-oauth -o jsonpath='{.data.client-secret}' | base64 -d > "$TMP/client-secret"
fi
{
  printf 'apiVersion: oauth.openshift.io/v1\nkind: OAuthClient\nmetadata:\n  name: grafana\n'
  printf '  labels:\n    app.kubernetes.io/part-of: grafana\n'
  printf 'grantMethod: auto\nredirectURIs:\n  - "%s"\n' "$REDIRECT_URI"
  printf 'secret: "%s"\n' "$(cat "$TMP/client-secret")"
} > "$TMP/oauthclient.yaml"

if [ "$(oc auth can-i create oauthclients 2>/dev/null)" = "yes" ] \
   && [ "$(oc auth can-i patch oauthclients 2>/dev/null)" = "yes" ]; then
  oc apply -f "$TMP/oauthclient.yaml" >/dev/null
  ok "OAuthClient grafana created/updated (redirect $REDIRECT_URI)"
  if [ "$need_client_secret" = 1 ]; then
    create_secret grafana-oauth "client-secret=$TMP/client-secret"
    ok "secret grafana-oauth created"
  fi
else
  mkdir -p "$RENDER_DIR"
  (umask 077 && cp "$TMP/oauthclient.yaml" "$RENDER_DIR/oauthclient.yaml")
  if [ "$need_client_secret" = 1 ]; then create_secret grafana-oauth "client-secret=$TMP/client-secret"; fi
  warn "you cannot create OAuthClients. A cluster administrator must run:"
  warn "    oc apply -f $RENDER_DIR/oauthclient.yaml"
  warn "then delete that file (it contains the client secret)."
fi

log "Done. Next: scripts/install.sh --check"
