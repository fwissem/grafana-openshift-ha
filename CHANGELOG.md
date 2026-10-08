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

## 2026-10-08 - local test stage

### Added
- Helm values for Grafana 13.2.3 (chart 13.3.1) with HA, a PostgreSQL backend,
  anonymous Viewer access and unified alerting in HA mode.
- PostgreSQL StatefulSet, backup CronJob and restore Job.
- Local functional test on kind with Podman on Windows. All 14 checks pass.
- Anonymity check (`scripts/check-anonymity.sh`) and read-only fact collection.
