# Changelog

All notable changes to this project. Dates are UTC.

## [Unreleased]

### Added
- OpenShift layer: Route (edge TLS, HTTP redirect), NetworkPolicies (default
  deny, router, monitoring, alerting gossip), ServiceMonitor and PrometheusRule.
- RHEL deployment scripts (bash): `create-secrets.sh`, `install.sh`
  (`--check` / `--apply` / `--rollback`), `db-backup-now.sh`, `db-restore.sh`,
  `export-grafana.sh`, `import-grafana.sh`, `db-backup-fetch.sh` (off-cluster copy of the dumps).
- `tests/openshift/acceptance.sh`: acceptance test on a real cluster.
- Private settings file `local/deploy.env` (template `deploy.env.example`),
  pre-filled by `collect-facts.sh target`.
- Security and contribution guides, pre-commit hook, CI (lint, secret scan,
  render and schema validation), EditorConfig.

### Changed
- PostgreSQL uses the Red Hat image `registry.redhat.io/rhel9/postgresql-16`
  (community build `quay.io/sclorg/postgresql-16-c9s` for local tests).
- `collect-facts.sh` runs per cluster (`source` / `target`) and prints an
  anonymised summary.
- Grafana runs only in the two data zones (4 replicas, 2 per zone); nothing
  runs in the quorum zone.

## 2026-10-08 - local test stage

### Added
- Helm values for Grafana 13.2.3 (chart 13.3.1): HA, PostgreSQL backend,
  anonymous Viewer access, unified alerting HA.
- PostgreSQL StatefulSet, backup CronJob, restore Job.
- Local functional test on kind with Podman (Windows): 14 checks, all passing.
- Anonymity guard (`scripts/check-anonymity.sh`) and read-only fact collection.
