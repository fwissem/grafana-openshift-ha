# grafana-openshift-ha

A production-grade, open-source Grafana for OpenShift: several replicas, state in
PostgreSQL, login through OpenShift OAuth, and anonymous read-only access to the
folders you choose to share. No operator, no GitOps requirement: plain Helm and
`oc`, installed by hand.

> **Status: skeleton.** The repository layout, the anonymity guard, the read-only
> fact collection and the local test pre-check are in place. Values files,
> manifests, dashboards and the runbook come next (see [Roadmap](#roadmap)).

## What this project fixes

A common Grafana setup on Kubernetes keeps its database (SQLite) inside the pod.
Dashboards created in the UI then disappear on the next restart, for example after
adding a datasource to the configuration. Here every piece of state lives in
PostgreSQL, so any Grafana pod can be deleted at any time without losing anything.

## Design in one page

| Need | Choice |
|---|---|
| High availability | 2-3 Grafana replicas spread across zones, PodDisruptionBudget, rolling updates |
| Persistence | PostgreSQL (StatefulSet on a replicated block volume) + scheduled dumps |
| Authentication | Grafana generic OAuth against the OpenShift OAuth server, groups mapped to roles |
| Sharing without login | `auth.anonymous` as Viewer, limited to designated folders |
| Datasources | Generated from a list in a private values file, with stable uids |
| Installation | `helm upgrade --install` from a locally untarred chart + `oc apply -k` |
| Secrets | Created on the cluster from a local, untracked file. Never in Git |

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
├── tests/local/
│   └── check-prereqs.sh          # what the local test machine has
├── values/                       # Helm values (public defaults + examples)   [next]
├── manifests/                    # PostgreSQL, Route, NetworkPolicies, ...    [next]
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
| Chart version | 13.2.5 | To be re-checked on the day of installation |
| Grafana version | 13.2.2 | appVersion of that chart |
| Images | `docker.io/grafana/grafana`, `docker.io/library/postgres` | Tags and digests are pinned in the values files (next step) |

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

Check what the local test machine has (read-only):

```bash
bash tests/local/check-prereqs.sh
```

## Roadmap

- [x] Skeleton, anonymity guard, fact collection, local pre-check
- [ ] Architecture note and design choices
- [ ] Values files, PostgreSQL and platform manifests, install / secrets scripts
- [ ] Local functional test (kind)
- [ ] Dashboards: Grafana health, PostgreSQL, fleet overview, capacity, nodes and upgrades, control plane, storage
- [ ] Runbook, migration from an existing instance, acceptance tests

## License

See [LICENSE](LICENSE).
