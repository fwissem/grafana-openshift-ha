# grafana-openshift-ha

A production-grade, open-source Grafana for OpenShift: several replicas, state in
PostgreSQL, login through OpenShift OAuth, and anonymous read-only access to the
folders you choose to share. No operator, no GitOps requirement: plain Helm and
`oc`, installed by hand.

> **Status: local test stage.** Helm values, PostgreSQL manifests (with backup
> and restore) and an automated local test on kind are in place. OpenShift
> manifests (Route, OAuth client, NetworkPolicies), dashboards and the runbook
> come next (see [Roadmap](#roadmap)).

## What this project fixes

A common Grafana setup on Kubernetes keeps its database (SQLite) inside the pod.
Dashboards created in the UI then disappear on the next restart, for example after
adding a datasource to the configuration. Here every piece of state lives in
PostgreSQL, so any Grafana pod can be deleted at any time without losing anything.

## Design in one page

| Need | Choice |
|---|---|
| High availability | 4 Grafana replicas, 2 per data zone, never in the quorum zone; PodDisruptionBudget, rolling updates |
| Persistence | PostgreSQL 16, Red Hat image (StatefulSet on a replicated block volume) + scheduled dumps |
| Authentication | Grafana generic OAuth against the OpenShift OAuth server, groups mapped to roles |
| Sharing without login | `auth.anonymous` as Viewer, limited to designated folders |
| Datasources | Generated from a list in a private values file, with stable uids |
| Installation | `helm upgrade --install` from a locally untarred chart + `oc apply -k` |
| Secrets | Created on the cluster from a local, untracked file. Never in Git |

Zones: the cluster has two data zones and a third zone that only provides
quorum. **No workload runs in the quorum zone**: Grafana, PostgreSQL, the
backup and restore jobs (and any component added later) are pinned to the two
data zones by node affinity; the zone names are set in `values-local.yaml` and the overlay.

Known limit, by design: PostgreSQL is a single instance on a replicated volume.
Losing its node means a short Grafana interruption while the pod is rescheduled,
with no data loss. An external managed PostgreSQL can be selected by values instead.

## Repository layout

```
.
├── README.md
├── docs/
│   └── PROMPT.md                 # the specification this project is built from
├── scripts/
│   ├── check-anonymity.sh        # blocks private strings before commit/push
│   └── collect-facts.sh          # phase 1: read-only facts from the cluster
├── values/
│   ├── values.yaml               # public defaults: HA, PostgreSQL, anonymous, alerting HA
│   ├── values-openshift.yaml     # restricted-v2 SCC, OpenShift OAuth (draft)
│   └── values-local.yaml.example # template of the private values (URLs, datasources)
├── manifests/
│   ├── base/                     # PostgreSQL StatefulSet, services, NetworkPolicy, backup CronJob
│   ├── overlays/kind/            # local test cluster (arbitrary UID like OpenShift)
│   └── restore/                  # restore Job, applied on purpose only
├── tests/local/
│   ├── kind-config.yaml          # 2 data zones x 2 workers + 1 quorum-zone worker
│   ├── run-test.ps1              # automated functional test (Windows + Podman)
│   └── ...
├── dashboards/                   # provisioned dashboards (JSON)              [next]
└── charts/                       # NOT in Git: untarred Grafana chart goes here
```

Private files, all git-ignored: `values-local.yaml`, `secrets.local.env`,
`.anonymity-denylist`, `local/`, `exports/`, `charts/`, `tests/local/out/`.

## Helm chart and images

The chart is **not** stored in this repository. Download it by hand, untar it into
`charts/grafana/`, and install from that directory.

| Item | Value | Note |
|---|---|---|
| Chart | `grafana` from `grafana-community/helm-charts` | The Grafana chart moved there from `grafana/helm-charts` |
| Chart version | 13.3.1 | Latest release on 2026-10-08; re-check on installation day |
| Grafana version | 13.2.3 | Image `docker.io/grafana/grafana:13.2.3-distroless` |
| PostgreSQL | `registry.redhat.io/rhel9/postgresql-16` | Red Hat image, built for OpenShift (arbitrary UID); needs the cluster pull secret or an internal mirror. Local test uses its community build `quay.io/sclorg/postgresql-16-c9s` |

Download and untar the chart (Windows example; same commands on Linux):

```powershell
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm pull grafana-community/grafana --version 13.3.1 --untar --untardir D:\grafana-openshift-ha\charts
```

The image registry prefix is a single parameter, so it can point at an internal
proxy of Docker Hub on an air-gapped cluster.

## Keeping the repository anonymous

This repository is public. No company name, internal domain, hostname, cluster
name, IP address, group name or secret may appear in a tracked file.

```bash
cp .anonymity-denylist.example .anonymity-denylist   # then list your private strings
scripts/check-anonymity.sh                           # run before every commit
```

The script scans everything Git would publish and exits non-zero on a match.

## Phase 1: collect facts from the cluster (read-only)

```bash
oc whoami --show-server        # confirm you are on the intended cluster
scripts/collect-facts.sh -o <namespace-of-the-current-grafana> -n <new-namespace>
```

Only `oc get`, `oc version`, `oc whoami` and `oc auth can-i` are used. Output goes
to `local/collect-<timestamp>/` and contains real names: keep it local.

What it answers: is the current Grafana on ephemeral storage, which storage
classes and zones exist, how OAuth and groups are set up, whether User Workload
Monitoring is on, where the cluster may pull images from, and what the current
user is allowed to create.

## Testing

| Level | Where | Covers |
|---|---|---|
| 1. Static | anywhere | YAML and JSON validity, shell lint, anonymity check |
| 2. Functional | local Kubernetes (kind) on a workstation | persistence across pod deletion, adding a datasource, anonymous access, several replicas on one database, backup and restore |
| 3. Platform | non-production OpenShift | Route, OpenShift OAuth, `restricted-v2` SCC, storage, zone spread |

### Local functional test (Windows, Podman Desktop, kind)

Prerequisites: Podman Desktop with a running machine, `kind`, `kubectl` and
`helm` (`winget install --id Kubernetes.kind -e`, `Kubernetes.kubectl`,
`Helm.Helm`), and the chart untarred in `charts\grafana`. Check them with:

```powershell
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\check-podman.ps1
```

Run the test (creates or reuses the kind cluster `grafana-ha`):

```powershell
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1
```

| Test | What it proves |
|---|---|
| T01-T02 | 4 replicas ready, 2 per data zone, nothing in the quorum zone |
| T03 | state in PostgreSQL, no Grafana volume |
| T04 | alerting cluster formed between replicas |
| T05-T07 | folders, dashboards, user, permissions; anonymous sees the shared folder only; same content on every replica |
| T08 | every Grafana pod deleted at once: nothing lost |
| T09 | a datasource added with `helm upgrade`: pods rolled, nothing lost (the original defect) |
| T10 | one pod killed while clients poll: no failed request |
| T11 | a whole data zone drained while clients poll: service continues, quorum zone stays unused |
| T12 | only labelled clients reach PostgreSQL |
| T13 | backup, dashboard deleted, database restored, dashboard back |
| T14 | no pod of the namespace, jobs and test pods included, ever ran in the quorum zone |

Set a new admin password on the test cluster (letters and digits only; Grafana
and the Secret are updated together, the password is only printed):

```powershell
powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\reset-admin-password.ps1
```

Results go to `tests\local\out\results.txt` (git-ignored). Options:
`-Recreate` (fresh cluster), `-SkipDeploy` (tests only), `-Destroy` (delete the cluster).

## Roadmap

- [x] Skeleton, anonymity guard, fact collection, local pre-check
- [x] Values files, PostgreSQL manifests, backup and restore
- [x] Local functional test (kind) - written, first run pending
- [ ] Architecture note and design choices
- [ ] OpenShift overlay (Route, OAuthClient, NetworkPolicies, ServiceMonitor), install / secrets scripts
- [ ] Dashboards: Grafana health, PostgreSQL, fleet overview, capacity, nodes and upgrades, control plane, storage
- [ ] Runbook, migration from an existing instance, acceptance tests

## License

See [LICENSE](LICENSE).
