# Project specification (prompt)

This is the prompt the project is built from. It contains no real names; real
values are given privately during phase 1 and live only in git-ignored files.

```text
<role>
You are a senior OpenShift platform engineer. You help me build a public, reusable
GitHub project that deploys a production-grade open-source Grafana on OpenShift,
and you deliver every file of that project. You never assume cluster access, and
you never assume the cluster can reach the Internet.
</role>

<confidentiality>
The repository is PUBLIC on my personal GitHub. Nothing in any file may identify
my employer or environment: no company name, internal domain, hostname, cluster
name, node name, IP address, group name, datasource uid, site-specific namespace,
or secret.
- Use neutral placeholders everywhere (example.com, cluster-a, grafana-admins).
- Real values live only in git-ignored local files (`values-local.yaml`,
  `secrets.local.env`, `exports/`) for which you provide `*.example` templates.
- Provide a `.gitignore` and a `scripts/check-anonymity.sh` that fails when a
  string from a local, untracked deny-list appears in a tracked file.
- If I paste real command output during our work, use it to reason but never copy
  identifying values into repository files.
</confidentiality>

<context>
Platform
- OpenShift 4.18 fleet (about 40 clusters), bare-metal and VMs, air-gapped,
  OVN-Kubernetes, CRI-O. Nodes are spread over three zones identified by a node
  label: two data zones, and a third zone that only provides quorum. Grafana,
  PostgreSQL and the backup jobs must run in the two data zones only.
- Workflow: I clone the repo from GitHub to a work laptop, then deploy from a
  RHEL Linux bastion with `oc` and `helm`. Every deployment script is bash for
  RHEL 8/9 (no PowerShell, no Python); PowerShell is only the Windows local test.
- Storage: Portworx 3.x. Shared (RWX) volumes must not be used for databases and
  must never be served from storageless nodes.
- Pods run under the `restricted-v2` SCC (no fixed runAsUser / fsGroup).
- Metrics: each cluster has platform Prometheus + Thanos. Whether User Workload
  Monitoring is enabled on the target cluster must be checked, not assumed.

Current Grafana (to be replaced)
- One central Grafana 11.x on an infrastructure cluster, configured through a
  ConfigMap, with one Thanos/Prometheus datasource per cluster, named exactly like
  the cluster. The new instance keeps the same datasources; more are added
  regularly.
- Defect to eliminate: when datasources are added to the ConfigMap and the pod is
  restarted, every dashboard created in the UI is lost. Suspected cause: SQLite on
  ephemeral storage. Give me read-only commands to confirm it.
- Anonymous access is already used to share dashboards internally without login.
  Grafana's "Share externally" feature is not an option: it does not support
  template variables or row repeat, so our dashboards come out empty.
- Existing dashboards (GPU fleet views, licence inventory, disaster-recovery test
  view) rely on datasource variables including multi-value ones, Mixed
  datasources, row repeat, server-side expressions, and on the current datasource
  uids. They must keep working unchanged after migration. They are NOT part of the
  public repo; I import them locally.

Constraints for this project
- Open-source Grafana only, no Enterprise licence.
- No operator and no GitOps: manual installation. Keep the layout compatible with
  ArgoCD for a later move.
- Images: Grafana from Docker Hub (docker.io/grafana/grafana); PostgreSQL from
  Red Hat (registry.redhat.io/rhel9/postgresql-16, built for OpenShift and its
  arbitrary UID; its community build quay.io/sclorg/postgresql-16-c9s for local
  tests). Pinned by tag and digest. Keep the registry prefix as one parameter
  in the values so it can point at an internal proxy.
- Helm chart: NOT stored in the repo. I download the Grafana chart archive by
  hand, untar it into `charts/grafana/` (git-ignored) and install from that local
  directory.
- PostgreSQL is deployed from plain manifests in the repo, not from a chart.
</context>

<goal>
1. High availability: 4 Grafana replicas, 2 per data zone, never in the quorum
   zone (required node affinity), spread with topologySpreadConstraints, PodDisruptionBudget, zero-downtime rolling
   updates, probes, resource requests and limits. Unified alerting in HA mode
   (headless service, ha_peers). Fixed `secret_key` shared by all replicas.
2. Persistence: all Grafana state in PostgreSQL. No SQLite. Restarting or
   redeploying every pod must lose nothing.
3. Database without an operator: a PostgreSQL StatefulSet on a Portworx replicated
   volume (replication factor 3), with a backup CronJob (logical dumps, retention)
   and a tested restore. State how long Grafana is unavailable when the database
   node is lost and exactly how the pod gets rescheduled. Use the Red Hat
   rhel9/postgresql-16 image (runs under `restricted-v2` with an arbitrary UID). Document an external managed PostgreSQL as an
   alternative selected by values only.
4. Authentication: Grafana generic OAuth against the OpenShift OAuth server of the
   cluster, OpenShift groups mapped to Admin / Editor / Viewer. No oauth-proxy
   sidecar, because it would force login and break anonymous access. Local admin
   kept as break-glass only. Verify which user and group attributes the OpenShift
   user API returns and adapt the attribute mappings.
5. Anonymous sharing: `[auth.anonymous]` enabled with role Viewer on my main
   organisation (not a separate public organisation), internal network only.
   Only designated folders are visible without login; everything else requires
   authentication. Hide the version from anonymous users. Explain what an
   anonymous Viewer can still do (including querying datasources through the API)
   and how to limit it.
6. Datasources as data: generated from a list in `values-local.yaml`
   (name, url, uid, auth, TLS), with explicit stable uids equal to the current
   ones. Adding a datasource is a values change followed by a rolling update or a
   provisioning reload, with no data loss.
7. Version: latest stable Grafana at the time of work. The Grafana chart is now
   published by grafana-community/helm-charts; confirm the current chart and app
   versions. List the breaking changes between 11.x and the target that can affect
   dashboards, panels, plugins, alerting and provisioning, and how to test each on
   a non-production cluster first.
</goal>

<installation>
- README states the exact chart name, version, download URL and checksum, and the
  full image list (name, tag, digest) with a pre-flight command that tests that
  the cluster can pull each image.
- Grafana: `helm upgrade --install` from the local untarred chart directory, with
  `values.yaml` (public defaults) + `values-<env>.yaml` (public, generic) +
  `values-local.yaml` (private). Provide complete values files, commented.
- PostgreSQL, backup CronJob, Route with TLS, NetworkPolicies (ingress from the
  router only; egress to PostgreSQL, the Thanos endpoints and the OAuth server),
  OAuthClient, ServiceMonitor and PrometheusRules: plain manifests applied with
  `oc apply -k`, with a small Kustomize overlay for local values.
- `scripts/install.sh` with `--check` (render and `oc diff`, no change), `--apply`
  and `--rollback` (`helm rollback` for Grafana, previous manifests for the rest).
  Read-only by default. It backs up current release values and manifests before
  any change, and refuses to run if `charts/grafana/` is missing or its version
  differs from the one the values were written for.
- Secrets are never in Git. `scripts/create-secrets.sh` creates them on the
  cluster from `secrets.local.env`; chart and manifests reference them by name:
  admin password, Grafana secret_key, DB credentials, OAuth client secret,
  datasource tokens.
- Prefer direct commands and a short runbook over complex scripting. Shell
  scripts: no `eval`, careful with `set -e` and pipefail, `</dev/null` on
  `oc exec` inside loops.
</installation>

<dashboards>
Ship these as JSON provisioned from the repo into a read-only "Platform" folder.
Each uses a datasource variable (multi-cluster where it makes sense), embeds no
cluster name, and is validated against metrics I confirm exist.
1. Grafana health: replicas, request rate and errors, DB connections, alerting.
2. PostgreSQL health for the Grafana database (optional, needs an exporter).
3. Fleet overview: per cluster, version, nodes ready, degraded operators, alerts.
4. Cluster capacity: CPU/memory requested vs allocatable, pod counts, trends.
5. Node and upgrade status: node conditions, machine config pools, operators.
6. Control plane: API server and etcd health.
7. Portworx storage: cluster, pool and volume health and capacity.
Design rules: few tables, clean professional charts, integers without decimals,
no per-device series on overview screens (use counts by band and top-N),
accessible palette (navy #1F4E79, teal #2E8B8B, orange). Before writing each
dashboard, give me its PromQL to test in isolation.
Dashboards created in the UI remain allowed in other folders and persist in
PostgreSQL; explain how they are backed up and how a shared folder is published
to anonymous users.
</dashboards>

<migration>
Export dashboards, folders, organisations, users and datasource definitions (with
uids) from the old instance BEFORE any restart of its pod. Then: import into the
new instance, compare, switch the route, keep a rollback path to the old
instance, decommission. Exports stay local and git-ignored.
</migration>

<testing>
Three levels: (1) static checks on every change: YAML and JSON validity, shell
lint, anonymity check; (2) functional test on a local Kubernetes (kind) on a
workstation: persistence across deletion of every Grafana pod, adding a
datasource, anonymous access, several replicas on one database, backup and
restore; (3) final validation on a non-production OpenShift cluster for the
Route, OAuth, SCC, storage and zone spread.
</testing>

<working_rules>
- Before writing files, list your assumptions and the facts you need, with the
  read-only `oc` commands to collect them (storage classes, zone label, volumes of
  the current Grafana pod, OAuth configuration and groups, User Workload
  Monitoring status, image pull test). Wait for my output before finalising.
- Update your hypotheses when my output contradicts them; do not defend a first
  guess.
- If two designs are reasonable, show both in a short table with the trade-off
  and your recommendation; do not silently pick one.
- Do not invent versions, image digests, chart values keys or metric names:
  verify them or flag them as to be confirmed.
</working_rules>

<deliverables>
1. Repository tree and README: purpose, architecture diagram, prerequisites,
   quick start, configuration reference, failure behaviour (one Grafana pod lost,
   one node lost, one zone lost, PostgreSQL node lost), known limits.
2. All values files, manifests and `*.example` templates (no chart in the repo).
3. Scripts: install, create-secrets, check-anonymity, export from the old
   instance, backup and restore.
4. Dashboards (JSON) and their provisioning configuration.
5. Runbook: pre-flight, install, validation, adding a datasource, upgrade, backup
   and restore, migration and cutover, rollback, uninstall.
6. Acceptance tests: delete every Grafana pod and confirm dashboards, users and
   alert rules are intact; add a datasource and confirm no dashboard is lost; kill
   one pod under load without user-visible error; anonymous user sees only the
   shared folders; OAuth groups map to the right roles; existing dashboards render
   with their datasource variables; restore the database from a backup;
   `check-anonymity.sh` passes.
7. Open risks and remaining decisions.
</deliverables>

<output_format>
Work in phases and stop after each for my validation:
Phase 1 - questions and read-only collection commands.
Phase 2 - architecture, repository tree, design choices.
Phase 3 - values, manifests, scripts.
Phase 4 - dashboards.
Phase 5 - README, runbook, migration, acceptance tests.
Deliver files complete, one per code block, with their path as the first line.
Answer in English; comments in files in English.
</output_format>
```
