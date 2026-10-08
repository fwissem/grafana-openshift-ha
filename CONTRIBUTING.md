# Contributing

## Rules

Never commit environment data. That means no hostname, cluster or namespace
name, zone name, group name, IP address, datasource URL or uid, and no secret.
Use neutral placeholders such as `example.com`, `cluster-a` and `zone-a`, and
keep real values in git-ignored files (`local/`, `values/values-local.yaml`).

Scripts that change a cluster are read-only by default. They have a `--check`
mode that shows what would change, and they change nothing without `--apply` or
an explicit confirmation.

Deployment scripts are bash for RHEL 8 and 9. They use only `oc`, `helm`,
`curl` and coreutils, plus `jq` for the export and import scripts. PowerShell
appears only in the Windows local test under `tests/local/`.

Nothing runs in the quorum zone. Every Deployment, StatefulSet, Job and CronJob
carries the data-zone node affinity, and `install.sh` refuses to render a
workload that lacks it.

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

If you changed manifests or values, also run the local test
(`tests/local/run-test.ps1`, see the README) and the OpenShift acceptance test
on a non-production cluster (`tests/openshift/acceptance.sh`).

## Commits

Keep commits small, and say in the message what changed and why. Add an entry
to `CHANGELOG.md` for any change that someone using the repository would notice.
