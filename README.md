# grafana-openshift-ha

This repository deploys open-source Grafana on OpenShift with four replicas,
its data in PostgreSQL, login through OpenShift, and anonymous read-only access
to the folders you decide to share. You install it by hand from a RHEL machine
with Helm and `oc`. It needs no operator and no GitOps tool.

[![ci](https://github.com/fwissem/grafana-openshift-ha/actions/workflows/ci.yml/badge.svg)](https://github.com/fwissem/grafana-openshift-ha/actions/workflows/ci.yml)

## Why

When Grafana keeps its SQLite database inside the pod, a restart wipes every
dashboard created in the UI. Adding a datasource to the ConfigMap triggers such
a restart, which is how the problem usually shows up. This deployment keeps all
state in PostgreSQL instead, so you can delete any Grafana pod at any time. The
local test deletes all of them at once and checks that the dashboards, users
and permissions are still there.

## What it deploys

| Need | How |
|---|---|
| High availability | 4 Grafana replicas, 2 per data zone and spread over the nodes, a PodDisruptionBudget and rolling updates that keep every replica up until its replacement is ready |
| Zones | The two data zones run everything. The third zone only provides quorum and runs nothing from this project |
| Persistence | PostgreSQL 16 (Red Hat `rhel9/postgresql-16`) on a replicated block volume, with a daily dump and a tested restore |
| Login | OpenShift OAuth, with OpenShift groups mapped to Admin, Editor or Viewer. The local admin account stays as a break-glass login |
| Sharing | Anonymous Viewer access. A folder is public when the Viewer role can see it |
| Alerting | Unified alerting in HA mode, so the replicas share silences and notification state |
| Exposure | A Route with edge TLS that redirects HTTP to HTTPS, and NetworkPolicies that deny ingress by default |
| Monitoring | A ServiceMonitor and alert rules for User Workload Monitoring |
| Migration | Scripts to export dashboards, folders, permissions and datasources from an existing Grafana and import them here |

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the design and what happens when a pod, a node, a zone or the database fails.

## Versions

| Component | Version | Image |
|---|---|---|
| Grafana Helm chart | 13.3.1 (`grafana-community/helm-charts`) | not stored here, you download it by hand |
| Grafana | 13.2.3 | `docker.io/grafana/grafana:13.2.3-distroless` |
| PostgreSQL | 16 | `registry.redhat.io/rhel9/postgresql-16` (local tests use `quay.io/sclorg/postgresql-16-c9s`) |
| OpenShift | 4.18 (Kubernetes 1.31) or later | |
| Deployment machine | RHEL 8 or 9 with `oc`, `helm` 3 or 4, `curl` and `jq` | |

## Quick start on the RHEL machine

The full procedure, day-2 operations and the cutover from an old instance are in
[docs/RUNBOOK.md](docs/RUNBOOK.md).

```bash
git clone https://github.com/fwissem/grafana-openshift-ha /opt/grafana-openshift-ha
cd /opt/grafana-openshift-ha

# 1. Download and untar the chart
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm pull grafana-community/grafana --version 13.3.1 --untar --untardir /opt/grafana-openshift-ha/charts

# 2. Collect facts (read-only). The target run writes local/deploy.env.generated
scripts/collect-facts.sh source -n <current-ns> --kubeconfig <kubeconfig-of-current-cluster>
scripts/collect-facts.sh target -n <new-ns>     --kubeconfig <kubeconfig-of-target-cluster>
#    edit it (keep only the two data zones), then:
mv local/deploy.env.generated local/deploy.env

# 3. Export the current Grafana, then write values/values-local.yaml
GRAFANA_USER=admin scripts/export-grafana.sh --url https://<current-grafana>
cp values/values-local.yaml.example values/values-local.yaml   # paste the exported datasources

# 4. Create the secrets, install, validate, import
scripts/create-secrets.sh --check && scripts/create-secrets.sh --apply
scripts/install.sh --check        && scripts/install.sh --apply
tests/openshift/acceptance.sh
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route> --apply
```

Scripts that change the cluster run in a read-only `--check` mode first. With
`--apply` they print the plan and ask for confirmation before they change
anything.

## Repository layout

```
.
├── values/
│   ├── values.yaml                  public defaults (HA, PostgreSQL, anonymous access, alerting HA)
│   ├── values-openshift.yaml        restricted-v2 SCC, OpenShift OAuth
│   └── values-local.yaml.example    template for the private values (datasources)
├── manifests/
│   ├── base/                        PostgreSQL, its NetworkPolicy, backup CronJob
│   ├── overlays/openshift/          Route, NetworkPolicies, ServiceMonitor, alert rules
│   ├── overlays/kind/               local test cluster
│   └── restore/                     restore Job, applied only during a restore
├── scripts/
│   ├── collect-facts.sh             read-only facts per cluster and an anonymised summary
│   ├── create-secrets.sh            Secrets, OAuthClient, CA bundle (--check/--apply)
│   ├── install.sh                   render, diff, deploy, roll back
│   ├── export-grafana.sh            export an existing Grafana (read-only)
│   ├── import-grafana.sh            import into the new Grafana (--check/--apply)
│   ├── db-backup-now.sh             run a backup now
│   ├── db-backup-fetch.sh           copy dumps out of the cluster
│   ├── db-restore.sh                restore a dump
│   ├── check-anonymity.sh           blocks private strings before a commit
│   └── lib/                         shared bash helpers
├── tests/
│   ├── openshift/acceptance.sh      acceptance test on a real cluster
│   └── local/                       functional test on kind (Windows and Podman)
├── docs/                            ARCHITECTURE, RUNBOOK, PROMPT (the original specification)
├── deploy.env.example               template for the private settings
├── .githooks/pre-commit             anonymity and secret checks
└── .github/workflows/ci.yml         lint, secret scan, rendering and schema validation
```

Git ignores the private files: `local/` (settings, rendered manifests, backups,
reports), `values/values-local.yaml`, `exports/`, `charts/` and
`.anonymity-denylist`.

## Security

The repository is public and holds no environment data and no secret. The
scripts generate secrets on the deployment machine and store them only in the
cluster. [SECURITY.md](SECURITY.md) lists what is protected, how, and the
exposures to keep in mind, the main one being that anonymous users can query
every datasource of the organisation.

If you plan to commit from your clone, turn on the hook and fill in your
deny-list first:

```bash
git config core.hooksPath .githooks
cp .anonymity-denylist.example .anonymity-denylist   # then list your private strings
```

## Testing

| Level | Where | What it checks |
|---|---|---|
| Static | CI, on every push | shellcheck, yamllint, gitleaks, kustomize and Helm rendering, Kubernetes schema validation |
| Functional | kind on a Windows workstation with Podman ([tests/local](tests/local)) | 14 checks covering replicas and zones, PostgreSQL state, alerting HA, anonymous access, deletion of every pod, a datasource added with Helm, pod and zone loss under load, the PostgreSQL NetworkPolicy, backup and restore, and an empty quorum zone |
| Acceptance | non-production OpenShift (`tests/openshift/acceptance.sh`) | the same checks on the real platform, plus the Route certificate and the OAuth redirect |

To run the local functional test on Windows, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\check-podman.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\reset-admin-password.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1 -Destroy
```

`run-test.ps1` takes `-Recreate` to start from a fresh cluster, `-SkipDeploy` to
run the tests only, and `-Destroy` to delete the cluster. It writes its results
to `tests\local\out\results.txt`.

## Roadmap

- [x] HA Grafana on PostgreSQL, zones, anonymous access, alerting HA
- [x] Local functional test, all checks passing
- [x] OpenShift layer, RHEL deployment scripts, export and import, acceptance test
- [ ] First run on a non-production OpenShift cluster
- [ ] Provisioned platform dashboards (Grafana health, PostgreSQL, fleet overview, capacity, nodes and upgrades, control plane, storage)
- [ ] Production cutover

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). The project is licensed under the GNU
GPL v3.0, see [LICENSE](LICENSE).
