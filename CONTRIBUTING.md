# Contributing

## Ground rules

- **Never commit environment data.** No hostname, cluster or namespace name,
  zone name, group name, IP address, datasource URL or uid, and no secret.
  Use neutral placeholders (`example.com`, `cluster-a`, `zone-a`). Real values
  belong in git-ignored files (`local/`, `values/values-local.yaml`).
- **Read-only by default.** A script that changes a cluster has a `--check`
  mode that only shows what would change, and changes nothing without
  `--apply` (or an explicit confirmation).
- **Deployment scripts are bash for RHEL 8/9** and use only `oc`, `helm`,
  `curl` and coreutils (`jq` for the export/import scripts). PowerShell is used
  only for the Windows local test in `tests/local/`.
- **No workload in the quorum zone.** Every Deployment, StatefulSet, Job and
  CronJob carries the data-zone node affinity. `install.sh` refuses to render a
  workload without it.

## Setup after cloning

```bash
git config core.hooksPath .githooks            # pre-commit checks
cp .anonymity-denylist.example .anonymity-denylist
# list your private strings in .anonymity-denylist (company, domains, cluster prefixes)
```

## Before opening a pull request

```bash
scripts/check-anonymity.sh
shellcheck -S warning -x scripts/*.sh scripts/lib/*.sh tests/openshift/*.sh
```

and, for changes to manifests or values, the local test
(`tests/local/run-test.ps1`, see README) and the OpenShift acceptance test on a
non-production cluster (`tests/openshift/acceptance.sh`).

## Commits

Small commits with a message saying what changed and why. Update
`CHANGELOG.md` for any change a user of the repository would notice.
