# Changelog

Changes that affect users of this repository. Dates are UTC.

## [Unreleased]

### Added
- OpenShift layer: a Route with edge TLS and HTTP redirect, NetworkPolicies
  (default deny, router, monitoring, alerting gossip), a ServiceMonitor and a
  PrometheusRule.
- Bash deployment scripts for RHEL: `create-secrets.sh`, `install.sh` with
  `--check`, `--apply` and `--rollback`, `db-backup-now.sh`, `db-restore.sh`,
  `db-backup-fetch.sh` to copy dumps off the cluster, `export-grafana.sh` and
  `import-grafana.sh`.
- `tests/openshift/acceptance.sh`, an acceptance test for a real cluster.
- The private settings file `local/deploy.env`, built from
  `deploy.env.example` and pre-filled by `collect-facts.sh target`.
- Security and contribution guides, a pre-commit hook, CI (lint, secret scan,
  rendering and schema validation) and an EditorConfig file.

### Changed
- PostgreSQL uses the Red Hat image `registry.redhat.io/rhel9/postgresql-16`.
  Local tests use the community build `quay.io/sclorg/postgresql-16-c9s`.
- `collect-facts.sh` runs once per cluster (`source` or `target`) and prints an
  anonymised summary.
- Grafana runs only in the two data zones, with 4 replicas, 2 per zone. Nothing
  runs in the quorum zone.
- Documentation rewritten in plainer language.

### Fixed
- `create-secrets.sh` no longer mistakes an API error for a missing secret, and
  creates the fixed secrets with `oc create`, so it can never overwrite the
  database password or the secret key.
- `db-restore.sh` stops as soon as the restore Job fails and always scales
  Grafana back up, also after an error or Ctrl-C.
- `install.sh --rollback` returns to the revision recorded by the last
  `--apply` instead of "previous".
- Grafana liveness uses `/healthz`, so a PostgreSQL restart no longer restarts
  every replica. Readiness still checks the database.
- PostgreSQL stops with a fast shutdown and has a startup probe for crash
  recovery.
- The router NetworkPolicy also admits host-network ingress controllers, and
  the monitoring policy admits User Workload Monitoring explicitly.
- Backups remove leftover temporary files, check each dump with
  `pg_restore --list`, and a new alert fires if no backup has ever succeeded.
- Acceptance test: no silent exit before A10, cleanup on any exit, database
  type read with jq.
- Smaller fixes: sessions limited to 24 hours, PDB lets unhealthy pods be
  evicted, pods restart when datasource tokens change, CI actions pinned to
  commit SHAs and kubeconform checked against its checksum.

## 2026-10-08 - local test stage

### Added
- Helm values for Grafana 13.2.3 (chart 13.3.1) with HA, a PostgreSQL backend,
  anonymous Viewer access and unified alerting in HA mode.
- PostgreSQL StatefulSet, backup CronJob and restore Job.
- Local functional test on kind with Podman on Windows. All 14 checks pass.
- Anonymity check (`scripts/check-anonymity.sh`) and read-only fact collection.
