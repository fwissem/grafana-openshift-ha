# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
vulnerability reporting on this repository (Security tab, then "Report a
vulnerability"). You should get an answer within a few working days.

## What this repository never contains

The repository is public and deploys into private environments, so it holds no
environment data and no secret. The table shows where each kind of data lives
instead.

| Kind of data | Where it lives |
|---|---|
| Passwords, secret key, OAuth client secret | `scripts/create-secrets.sh` generates them (24 to 40 random letters and digits) and stores them only as Kubernetes Secrets in the target namespace. |
| Datasource tokens | `local/datasource-tokens.env` on the deployment machine, then a Kubernetes Secret. |
| Cluster names, hostnames, zones, storage classes | `local/deploy.env` on the deployment machine. |
| Datasource URLs and uids | `values/values-local.yaml` on the deployment machine. |
| Exports of an existing Grafana | `exports/` on the deployment machine. |

Git ignores all of these paths, and three checks keep them out of a commit:

1. `.gitignore` covers private files, kubeconfigs, keys, certificates and tokens.
2. The pre-commit hook in `.githooks/pre-commit` refuses a commit that contains
   a string from your private `.anonymity-denylist`, a private key, an
   OpenShift or Grafana token, a JWT or a cloud access key. Turn it on with
   `git config core.hooksPath .githooks`.
3. CI runs gitleaks on every push.

## How the scripts handle secrets

The scripts generate secrets from `/dev/urandom` and write them only to a
private temporary directory (`umask 077`) that they delete on exit. They pass
secrets to `oc` as files, never on a command line, so the values stay out of
`ps` output and shell history.

No script prints a secret. To read one on purpose, run
`oc -n <ns> get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo`.

The scripts never overwrite an existing secret, because the database password
and the Grafana secret key must stay the same after the first start.

If your account cannot create the cluster-scoped OAuthClient,
`create-secrets.sh` writes its manifest to `local/render/oauthclient.yaml` with
mode 600 for an administrator. That file contains the client secret, so delete
it once the administrator has applied it.

## What the deployment enforces at runtime

Grafana and PostgreSQL run under the OpenShift `restricted-v2` SCC: an
arbitrary UID, no privilege escalation, all capabilities dropped and the
`RuntimeDefault` seccomp profile. Grafana uses the distroless image with a
read-only root filesystem.

The pods have no access to the Kubernetes API. They do not mount a service
account token and the chart creates no RBAC.

The NetworkPolicies deny ingress by default. Only the OpenShift router and the
monitoring stack can reach Grafana, only the Grafana replicas can talk to each
other on the gossip port 9094, and only pods labelled `grafana-db-client=true`
can reach PostgreSQL.

The route terminates TLS at the edge, redirects HTTP to HTTPS and Grafana sets
secure cookies. Analytics, update checks and the news feed are off, so Grafana
makes no calls to the Internet. Users log in through OpenShift OAuth, and the
local admin account remains only for break-glass access.

## Known exposures

Anonymous access (`auth.anonymous` with the Viewer role) is on so that people
inside the network can open shared dashboards. An anonymous viewer sees every
folder the Viewer role can see. More importantly, it can query every datasource
of the organisation through the API, because per-datasource permissions are a
Grafana Enterprise feature. Do not add a datasource to this organisation if
anonymous users must not query it, and keep the route on the internal network.

Grafana's `/metrics` endpoint is reachable through the route. It exposes
internal counters but no credentials and no dashboard data.

The PostgreSQL backups sit on a volume in the same cluster. Copy them off the
cluster as described in docs/RUNBOOK.md.

## Supported versions

Only the latest commit on `main` is maintained.
