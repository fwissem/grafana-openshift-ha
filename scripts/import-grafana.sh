#!/usr/bin/env bash
# import-grafana.sh - import an export made by export-grafana.sh into the new Grafana.
#
# --check (default) lists what would be done; --apply does it. Order:
#   1. folders (parents first), same uids
#   2. folder permissions granted to ROLES (Viewer/Editor): this is what makes a
#      folder visible to anonymous users or not. Permissions granted to users or
#      teams are listed, not imported (their ids differ on the new instance).
#   3. library panels
#   4. dashboards, same uids, in their folder
#   5. alert rules (only with --with-alerts; contact points are NOT imported:
#      their secrets are redacted by Grafana, recreate them by hand)
# Datasources are not imported here: they are provisioned from values-local.yaml
# (see datasources-values.yaml in the export).
#
# Existing objects are skipped unless --overwrite.
#
# Usage:
#   GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<ts> --url https://grafana.example.com [--apply] [--overwrite] [--with-alerts]
#   (GRAFANA_TOKEN, GRAFANA_CACERT, GRAFANA_INSECURE, GRAFANA_ORG_ID as for export-grafana.sh)

set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/grafana-api.sh
. "$(dirname "$0")/lib/grafana-api.sh"

DIR=""; URL=""; APPLY=0; OVERWRITE=0; ALERTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --check) APPLY=0; shift ;;
    --overwrite) OVERWRITE=1; shift ;;
    --with-alerts) ALERTS=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$DIR" ] && [ -n "$URL" ] || { sed -n '2,22p' "$0"; exit 2; }
[ -d "$DIR/dashboards" ] && [ -r "$DIR/folders.json" ] || die "$DIR is not an export directory"
need_tools curl jq
gapi_init "$URL"
init_secure_tmp; TMP="$SECURE_TMP"
mode="CHECK"; [ "$APPLY" = 1 ] && mode="APPLY"
log "import $DIR -> $URL ($mode, overwrite=$OVERWRITE, alerts=$ALERTS)"

exists() { [ "$(gapi GET "$1" /dev/null)" = 200 ]; }
created=0; skipped=0; failed=0

# 1. Folders, parents first: repeat passes until no progress.
pending="$(jq -c '[.[] | {uid, title, parentUid: (.folderUid // "")}]' "$DIR/folders.json")"
done_uids=" "
while :; do
  progress=0; next="[]"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    uid="$(jq -r .uid <<< "$f")"; parent="$(jq -r .parentUid <<< "$f")"
    if [ -n "$parent" ] && [[ "$done_uids" != *" $parent "* ]] && ! exists "/api/folders/$parent"; then
      next="$(jq -c --argjson x "$f" '. + [$x]' <<< "$next")"; continue
    fi
    if exists "/api/folders/$uid"; then
      skipped=$((skipped + 1))
    elif [ "$APPLY" = 1 ]; then
      jq '{uid, title} + (if .parentUid != "" then {parentUid} else {} end)' <<< "$f" > "$TMP/folder.json"
      code="$(gapi POST /api/folders "$TMP/out.json" "$TMP/folder.json")"
      if [ "$code" = 200 ]; then created=$((created + 1)); else failed=$((failed + 1)); warn "folder $uid: HTTP $code $(cat "$TMP/out.json")"; fi
    else
      echo "  would create folder $uid ($(jq -r .title <<< "$f"))"
    fi
    done_uids="$done_uids$uid "; progress=1
  done < <(jq -c '.[]' <<< "$pending")
  pending="$next"
  [ "$(jq 'length' <<< "$pending")" -gt 0 ] && [ "$progress" = 1 ] || break
done
[ "$(jq 'length' <<< "$pending")" -eq 0 ] || warn "folders with a missing parent: $(jq -r '[.[].uid] | join(", ")' <<< "$pending")"
ok "folders: created=$created skipped(existing)=$skipped failed=$failed"

# 2. Folder permissions granted to roles.
c=0
for p in "$DIR"/folder-permissions/*.json; do
  [ -e "$p" ] || continue
  uid="$(basename "$p" .json)"
  roles="$(jq -c '[.[] | select((.role // "") != "" and ((.inherited // false) | not)) | {role, permission}]' "$p")"
  others="$(jq '[.[] | select((.userId // 0) > 0 or (.teamId // 0) > 0)] | length' "$p")"
  [ "$others" -eq 0 ] || warn "folder $uid: $others user/team permission(s) not imported (recreate them by hand)"
  if [ "$APPLY" = 1 ]; then
    jq -n --argjson items "$roles" '{items: $items}' > "$TMP/perm.json"
    code="$(gapi POST "/api/folders/$uid/permissions" "$TMP/out.json" "$TMP/perm.json")"
    [ "$code" = 200 ] && c=$((c + 1)) || warn "permissions of $uid: HTTP $code"
  else
    echo "  would set role permissions on folder $uid: $(jq -r '[.[] | "\(.role)=\(.permission)"] | join(" ")' <<< "$roles")"
  fi
done
ok "folder role permissions applied: $c"

# 3. Library panels.
created=0; skipped=0; failed=0
if [ -r "$DIR/library-elements.json" ]; then
  while IFS= read -r el; do
    [ -n "$el" ] || continue
    uid="$(jq -r .uid <<< "$el")"
    if exists "/api/library-elements/$uid"; then skipped=$((skipped + 1)); continue; fi
    if [ "$APPLY" = 1 ]; then
      jq '{uid, name, kind, model, folderUid: (.folderUid // .meta.folderUid // "")}' <<< "$el" > "$TMP/el.json"
      code="$(gapi POST /api/library-elements "$TMP/out.json" "$TMP/el.json")"
      if [ "$code" = 200 ]; then created=$((created + 1)); else failed=$((failed + 1)); warn "library panel $uid: HTTP $code"; fi
    else
      echo "  would create library panel $uid"
    fi
  done < <(jq -c '.result.elements[]?' "$DIR/library-elements.json")
fi
ok "library panels: created=$created skipped=$skipped failed=$failed"

# 4. Dashboards.
created=0; skipped=0; failed=0
for d in "$DIR"/dashboards/*.json; do
  [ -e "$d" ] || continue
  uid="$(jq -r '.dashboard.uid' "$d")"
  if [ "$OVERWRITE" = 0 ] && exists "/api/dashboards/uid/$uid"; then skipped=$((skipped + 1)); continue; fi
  if [ "$APPLY" = 1 ]; then
    jq --argjson ow "$([ "$OVERWRITE" = 1 ] && echo true || echo false)" \
       '{dashboard: (.dashboard | .id = null), folderUid: (.meta.folderUid // ""), overwrite: $ow, message: "imported by import-grafana.sh"}' \
       "$d" > "$TMP/dash.json"
    code="$(gapi POST /api/dashboards/db "$TMP/out.json" "$TMP/dash.json")"
    if [ "$code" = 200 ]; then created=$((created + 1)); else failed=$((failed + 1)); warn "dashboard $uid: HTTP $code $(jq -r '.message // empty' "$TMP/out.json" 2>/dev/null)"; fi
  else
    echo "  would import dashboard $uid ($(jq -r '.dashboard.title' "$d"))"
  fi
done
ok "dashboards: imported=$created skipped(existing)=$skipped failed=$failed"

# 5. Alert rules (optional).
if [ "$ALERTS" = 1 ] && [ -r "$DIR/alert-rules.json" ]; then
  created=0; failed=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$APPLY" = 1 ]; then
      jq 'del(.id)' <<< "$r" > "$TMP/rule.json"
      code="$(gapi POST /api/v1/provisioning/alert-rules "$TMP/out.json" "$TMP/rule.json" 'X-Disable-Provenance: true')"
      if [ "$code" = 201 ] || [ "$code" = 200 ]; then created=$((created + 1)); else failed=$((failed + 1)); warn "alert rule $(jq -r .uid <<< "$r"): HTTP $code"; fi
    else
      echo "  would create alert rule $(jq -r .title <<< "$r")"
    fi
  done < <(jq -c '.[]' "$DIR/alert-rules.json")
  ok "alert rules: created=$created failed=$failed (recreate contact points by hand)"
fi

[ "$APPLY" = 1 ] || log "--check: nothing changed. Re-run with --apply."
