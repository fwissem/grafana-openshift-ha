# grafana-openshift-ha

Production-grade, open-source Grafana for OpenShift: highly available, state in
PostgreSQL, login with OpenShift OAuth, and anonymous read-only access to the
folders you choose to share. No operator and no GitOps requirement: Helm and
`oc`, run by hand from a RHEL machine.

[![ci](https://github.com/fwissem/grafana-openshift-ha/actions/workflows/ci.yml/badge.svg)](https://github.com/fwissem/grafana-openshift-ha/actions/workflows/ci.yml)

## Why

A Grafana that keeps its SQLite database inside the pod loses every dashboard
created in the UI on the next restart, for example after adding a datasource.
Here every piece of state lives in PostgreSQL: any Grafana pod can be deleted at
any time without losing anything. This is tested.

## What you get

| Need | How |
|---|---|
| High availability | 4 Grafana replicas, 2 per data zone, one per node; PodDisruptionBudget; zero-downtime rolling updates |
| Zones | Two data zones run everything; the third (quorum) zone never runs any workload of this project |
| Persistence | PostgreSQL 16 (Red Hat `rhel9/postgresql-16`) on a replicated block volume, daily dumps, tested restore |
| Login | OpenShift OAuth, OpenShift groups mapped to Admin / Editor / Viewer, local admin as break-glass |
| Sharing | Anonymous Viewer access; a folder is public when the Viewer role can see it |
| Alerting | Unified alerting in HA mode (replicas share state) |
| Exposure | Route with edge TLS, HTTP redirected, NetworkPolicies (default deny) |
| Monitoring | ServiceMonitor and alert rules for User Workload Monitoring |
| Migration | Export / import of dashboards, folders, permissions and datasources from an existing Grafana |

Details and failure behaviour: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Versions

| Component | Version | Image |
|---|---|---|
| Grafana Helm chart | 13.3.1 (`grafana-community/helm-charts`) | not stored here: downloaded by hand |
| Grafana | 13.2.3 | `docker.io/grafana/grafana:13.2.3-distroless` |
| PostgreSQL | 16 | `registry.redhat.io/rhel9/postgresql-16` (local tests: `quay.io/sclorg/postgresql-16-c9s`) |
| OpenShift | 4.18 (Kubernetes 1.31) or later | |
| Deployment machine | RHEL 8/9 with `oc`, `helm` 3 or 4, `curl`, `jq` | |

## Quick start (RHEL deployment machine)

Full procedure, day-2 operations and cutover: [docs/RUNBOOK.md](docs/RUNBOOK.md).

```bash
git clone https://github.com/fwissem/grafana-openshift-ha /opt/grafana-openshift-ha
cd /opt/grafana-openshift-ha

# 1. Chart, downloaded and untarred by hand
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm pull grafana-community/grafana --version 13.3.1 --untar --untardir /opt/grafana-openshift-ha/charts

# 2. Facts (read-only); pre-fills local/deploy.env.generated
scripts/collect-facts.sh source -n <current-ns> --kubeconfig <kubeconfig-of-current-cluster>
scripts/collect-facts.sh target -n <new-ns>     --kubeconfig <kubeconfig-of-target-cluster>
#    review it (keep only the two data zones), then:
mv local/deploy.env.generated local/deploy.env

# 3. Export the current Grafana, then write values/values-local.yaml
GRAFANA_USER=admin scripts/export-grafana.sh --url https://<current-grafana>
cp values/values-local.yaml.example values/values-local.yaml   # paste the exported datasources

# 4. Secrets, install, validate, import
scripts/create-secrets.sh --check && scripts/create-secrets.sh --apply
scripts/install.sh --check        && scripts/install.sh --apply
tests/openshift/acceptance.sh
GRAFANA_USER=admin scripts/import-grafana.sh --dir exports/<timestamp> --url https://<new-route> --apply
```

Every script that changes something has a read-only `--check` mode, shows its
plan, and asks before acting.

## Repository layout

```
.
├── values/
│   ├── values.yaml                  public defaults (HA, PostgreSQL, anonymous, alerting HA)
│   ├── values-openshift.yaml        restricted-v2 SCC, OpenShift OAuth
│   └── values-local.yaml.example    template of the private values (datasources)
├── manifests/
│   ├── base/                        PostgreSQL, its NetworkPolicy, backup CronJob
│   ├── overlays/openshift/          Route, NetworkPolicies, ServiceMonitor, alert rules
│   ├── overlays/kind/               local test cluster
│   └── restore/                     restore Job (applied on purpose only)
├── scripts/
│   ├── collect-facts.sh             read-only facts per cluster, anonymised summary
│   ├── create-secrets.sh            Secrets, OAuthClient, CA bundle (--check/--apply)
│   ├── install.sh                   render, diff, deploy, roll back
│   ├── export-grafana.sh            export an existing Grafana (read-only)
│   ├── import-grafana.sh            import into the new Grafana (--check/--apply)
│   ├── db-backup-now.sh             run a backup now
│   ├── db-backup-fetch.sh           copy dumps off-cluster
│   ├── db-restore.sh                restore a dump
│   ├── check-anonymity.sh           blocks private strings before a commit
│   └── lib/                         shared bash helpers
├── tests/
│   ├── openshift/acceptance.sh      acceptance test on a real cluster
│   └── local/                       functional test on kind (Windows + Podman)
├── docs/                            ARCHITECTURE, RUNBOOK, PROMPT (specification)
├── deploy.env.example               template of the private settings
├── .githooks/pre-commit             anonymity and secret checks
└── .github/workflows/ci.yml         lint, secret scan, render and schema validation
```

Private, git-ignored: `local/` (settings, rendered manifests, backups, reports),
`values/values-local.yaml`, `exports/`, `charts/`, `.anonymity-denylist`.

## Security

This repository is public and contains **no environment data and no secret**.
Secrets are generated on the deployment machine and stored only in the cluster.
See [SECURITY.md](SECURITY.md) for what is protected, how, and the known
exposures (anonymous access can query every datasource of the organisation).

After cloning, if you intend to commit:

```bash
git config core.hooksPath .githooks
cp .anonymity-denylist.example .anonymity-denylist   # then list your private strings
```

## Testing

| Level | Where | What |
|---|---|---|
| Static | CI, every push | shellcheck, yamllint, gitleaks, kustomize and Helm rendering, Kubernetes schema validation |
| Functional | kind on a Windows workstation with Podman ([tests/local](tests/local)) | 14 checks: replicas and zones, PostgreSQL state, alerting HA, anonymous access, all pods deleted, datasource added, pod and zone loss under load, NetworkPolicy, backup and restore, quorum zone empty |
| Acceptance | non-production OpenShift (`tests/openshift/acceptance.sh`) | same checks on the real platform, plus Route TLS and OAuth redirect |

Local functional test (Windows, PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\check-podman.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\reset-admin-password.ps1
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1 -Destroy
```

`run-test.ps1` options: `-Recreate` (fresh cluster), `-SkipDeploy` (tests only),
`-Destroy` (delete the cluster). Results: `tests\local\out\results.txt`.

## Roadmap

- [x] HA Grafana on PostgreSQL, zones, anonymous access, alerting HA
- [x] Local functional test (all checks passing)
- [x] OpenShift layer, RHEL deployment scripts, export / import, acceptance test
- [ ] First run on a non-production OpenShift cluster
- [ ] Provisioned platform dashboards (Grafana health, PostgreSQL, fleet overview, capacity, nodes and upgrades, control plane, storage)
- [ ] Production cutover

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under the terms in
[LICENSE](LICENSE) (GNU GPL v3.0).
