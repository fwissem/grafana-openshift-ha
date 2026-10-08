# Runbook

All commands run on the RHEL deployment machine, from the repository root, with
`oc` logged in to the target cluster (or `KUBECONFIG` exported). Scripts that
change something show the plan first and ask for confirmation.

Paths below assume the repository is at `/opt/grafana-openshift-ha`;
adapt them to where you cloned it.

## 0. One-time preparation

```bash
cd /opt/grafana-openshift-ha
git config core.hooksPath .githooks                # only if you commit from here

# Helm chart, downloaded by hand (from a machine with Internet if needed)
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm pull grafana-community/grafana --version 13.3.1 --untar --untardir /opt/grafana-openshift-ha/charts
```

Images the cluster must be able to pull (directly or through a mirror):
`docker.io/grafana/grafana:13.2.3-distroless` and
`registry.redhat.io/rhel9/postgresql-16`.

## 1. Collect facts (read-only)

```bash
scripts/collect-facts.sh source -n <current-ns> --kubeconfig <kubeconfig-of-current-cluster>
scripts/collect-facts.sh target -n <new-ns>     --kubeconfig <kubeconfig-of-target-cluster>
```

Review `local/deploy.env.generated`: keep only the two data zones in
`DATA_ZONES`, set the storage class, the group names, then:

```bash
mv local/deploy.env.generated local/deploy.env
chmod 600 local/deploy.env
```

## 2. Export the current Grafana (before anything restarts it)

```bash
GRAFANA_USER=admin scripts/export-grafana.sh --url https://<current-grafana-route>
```

Output: `exports/<timestamp>/`. Copy the datasources from
`exports/<timestamp>/datasources-values.yaml` into `values/values-local.yaml`
(start from `values/values-local.yaml.example`), and put their tokens in
`local/datasource-tokens.env` as `DS_TOKEN_<NAME>=<token>` lines (`chmod 600`).

## 3. Secrets and OAuth client

```bash
scripts/create-secrets.sh --check
scripts/create-secrets.sh --apply
```

Creating the OAuthClient needs cluster-admin. Without it, the script writes
`local/render/oauthclient.yaml` for an administrator, who runs
`oc apply -f local/render/oauthclient.yaml`; delete the file afterwards.

## 4. Install

```bash
scripts/install.sh --check      # renders and shows the diff, changes nothing
scripts/install.sh --apply      # backs up the current state, then deploys
```

## 5. Validate

```bash
tests/openshift/acceptance.sh                  # non-production
tests/openshift/acceptance.sh --with-restore   # also tests a restore (disruptive)
```

Then log in once with an OpenShift account of each group and check the role
(Admin, Editor, Viewer).

## 6. Import the content

```bash
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route>            # plan
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route> --apply    # do it
```

Check a few dashboards with their datasource variables, and that the shared
folders are visible without login.

## Day-2 operations

### Add or change a datasource

1. Edit `values/values-local.yaml` (keep the whole list: it replaces the previous one).
2. If it needs a token: add `DS_TOKEN_X=...` to `local/datasource-tokens.env`,
   then `scripts/create-secrets.sh --apply --refresh-tokens`.
3. `scripts/install.sh --check`, then `scripts/install.sh --apply`.

The replicas restart one by one; dashboards are not affected.

### Upgrade Grafana or the chart

1. Download the new chart into `charts/grafana` (remove the old directory first).
2. Set `CHART_VERSION` in `local/deploy.env` and, if pinned, the image tag in
   `values/values.yaml`.
3. Read the chart and Grafana release notes for breaking changes.
4. On non-production: `install.sh --check`, `--apply`, `acceptance.sh`.
5. Back up first (`scripts/db-backup-now.sh`): schema migrations run on the
   first start of a new version and are not reversible.

### Backups

- Daily at 01:15 UTC (`grafana-db-backup` CronJob), last 14 dumps kept.
- On demand: `scripts/db-backup-now.sh`.
- List the dumps: `scripts/db-restore.sh --list`.
- **Off-cluster copy** (recommended weekly): `scripts/db-backup-fetch.sh`
  copies the newest dump to `local/db-dumps/` (`--all` for every dump); move it
  to your backup storage from there.

### Restore

```bash
scripts/db-restore.sh --list
scripts/db-restore.sh --file latest            # or --file grafana-YYYYmmdd-HHMMSS.dump
```

Grafana is stopped during the restore (a few minutes) and restarted after.

### Rollback of a deployment

```bash
scripts/install.sh --rollback
```

Rolls back the Helm release to the previous revision and re-applies the
platform objects saved before the last `--apply`. A database schema migration
is not rolled back: restore the backup taken before the upgrade if needed.

### Admin password

Read: `oc -n <ns> get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`
Change: in Grafana (Administration > Users > admin), then update the secret to
match. The secret is only read when the admin user is first created.

## Cutover from the old instance

1. Freeze changes on the old Grafana (announce it).
2. Export again (`export-grafana.sh`) and import with `--overwrite`.
3. Point users to the new URL (or move the old route host to the new route).
4. Keep the old instance stopped but not deleted for two weeks: rollback = scale
   it back up and move the route back.
5. Decommission: delete the old namespace content after the retention period.

## Uninstall

```bash
helm uninstall grafana -n <ns>
oc delete -f local/render/platform.yaml        # route, policies, PostgreSQL, backups
oc -n <ns> delete pvc -l app.kubernetes.io/name=grafana-postgresql   # DATA LOSS
oc delete oauthclient grafana                  # cluster-admin
```
