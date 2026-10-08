# Runbook

Run every command on the RHEL deployment machine, from the repository root,
with `oc` logged in to the target cluster or `KUBECONFIG` exported. Scripts that
change something print their plan and ask for confirmation first.

The paths below assume the repository is in `/opt/grafana-openshift-ha`. Adapt
them if you cloned it somewhere else.

## 0. One-time preparation

```bash
cd /opt/grafana-openshift-ha
git config core.hooksPath .githooks                # only if you commit from here

# Download the Helm chart by hand (from a machine with Internet access if needed)
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm pull grafana-community/grafana --version 13.3.1 --untar --untardir /opt/grafana-openshift-ha/charts
```

The cluster must be able to pull two images, directly or through a mirror:
`docker.io/grafana/grafana:13.2.3-distroless` and
`registry.redhat.io/rhel9/postgresql-16`.

## 1. Collect facts (read-only)

```bash
scripts/collect-facts.sh source -n <current-ns> --kubeconfig <kubeconfig-of-current-cluster>
scripts/collect-facts.sh target -n <new-ns>     --kubeconfig <kubeconfig-of-target-cluster>
```

Open `local/deploy.env.generated`. Keep only the two data zones in
`DATA_ZONES`, set the storage class and the group names, then move it into
place:

```bash
mv local/deploy.env.generated local/deploy.env
chmod 600 local/deploy.env
```

## 2. Export the current Grafana before anything restarts it

```bash
GRAFANA_USER=admin scripts/export-grafana.sh --url https://<current-grafana-route>
```

The export goes to `exports/<timestamp>/`. Start `values/values-local.yaml`
from `values/values-local.yaml.example` and copy the datasources from
`exports/<timestamp>/datasources-values.yaml` into it. Put their tokens in
`local/datasource-tokens.env`, one `DS_TOKEN_<NAME>=<token>` line each, and set
the file to mode 600.

## 3. Secrets and OAuth client

```bash
scripts/create-secrets.sh --check
scripts/create-secrets.sh --apply
```

Creating the OAuthClient requires cluster-admin. Without that right, the script
writes `local/render/oauthclient.yaml`, and a cluster administrator applies it
with `oc apply -f local/render/oauthclient.yaml`. Delete the file afterwards
because it contains the client secret.

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

Then log in once with an OpenShift account from each group and check that it
gets the expected role (Admin, Editor or Viewer).

## 6. Import the content

```bash
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route>            # plan
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route> --apply    # import
```

Open a few dashboards and change their datasource variables. Then open the
shared folders in a private browser window to confirm they load without a login.

## Day-2 operations

### Add or change a datasource

1. Edit `values/values-local.yaml`. Keep the whole list, because it replaces the
   previous one.
2. If the datasource needs a token, add `DS_TOKEN_X=...` to
   `local/datasource-tokens.env` and run
   `scripts/create-secrets.sh --apply --refresh-tokens`.
3. Run `scripts/install.sh --check`, then `scripts/install.sh --apply`.

The replicas restart one at a time and the dashboards stay as they are.

### Upgrade Grafana or the chart

1. Remove `charts/grafana` and download the new chart in its place.
2. Set `CHART_VERSION` in `local/deploy.env`. If you pinned the image tag in
   `values/values.yaml`, update it too.
3. Read the chart and Grafana release notes for breaking changes.
4. Take a backup with `scripts/db-backup-now.sh`. A new Grafana version migrates
   the database schema on its first start, and that migration cannot be undone.
5. On a non-production cluster, run `install.sh --check`, `install.sh --apply`
   and `acceptance.sh`.

### Backups

The `grafana-db-backup` CronJob dumps the database every day at 01:15 UTC and
keeps the last 14 dumps. `scripts/db-backup-now.sh` takes one on demand and
`scripts/db-restore.sh --list` lists them.

Those dumps stay on a volume in the same cluster, so copy them out about once a
week. `scripts/db-backup-fetch.sh` copies the newest dump to `local/db-dumps/`
(add `--all` for every dump), and you move it to your backup storage from there.

### Restore

```bash
scripts/db-restore.sh --list
scripts/db-restore.sh --file latest            # or --file grafana-YYYYmmdd-HHMMSS.dump
```

The script stops Grafana for the few minutes the restore takes and starts it
again afterwards.

### Roll back a deployment

```bash
scripts/install.sh --rollback
```

This returns the Helm release to its previous revision and re-applies the
platform objects saved before the last `--apply`. It does not undo a database
schema migration. If an upgrade migrated the schema, restore the backup you took
before it.

### Admin password

To read it, run
`oc -n <ns> get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`.

To change it, use Grafana (Administration > Users > admin) and then update the
secret to match. Grafana reads the secret only when it first creates the admin
user.

## Cutover from the old instance

1. Announce a change freeze on the old Grafana.
2. Run `export-grafana.sh` again and import with `--overwrite`.
3. Send users to the new URL, or move the old route host to the new route.
4. Stop the old instance but keep it for two weeks. To roll back during that
   time, scale it up again and move the route back.
5. After those two weeks, delete what is left in the old namespace.

## Uninstall

```bash
helm uninstall grafana -n <ns>
oc delete -f local/render/platform.yaml        # route, policies, PostgreSQL, backups
oc -n <ns> delete pvc -l app.kubernetes.io/name=grafana-postgresql   # DATA LOSS
oc delete oauthclient grafana                  # cluster-admin
```
