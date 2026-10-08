# Architecture

## Components

```mermaid
flowchart LR
  user([Users and anonymous viewers]) -->|HTTPS| router[OpenShift router<br/>Route grafana, edge TLS]
  router --> svc[Service grafana]
  subgraph A[Data zone A]
    g1[Grafana 1]
    g2[Grafana 2]
  end
  subgraph B[Data zone B]
    g3[Grafana 3]
    g4[Grafana 4]
    pg[(PostgreSQL 16<br/>StatefulSet, 1 replica)]
  end
  subgraph Q[Quorum zone]
    none[no workload]
  end
  svc --> g1 & g2 & g3 & g4
  g1 & g2 & g3 & g4 -->|SQL| pg
  g1 <-.->|gossip 9094| g3
  pg --- vol[(Replicated block volume)]
  cron[Backup CronJob<br/>daily pg_dump] --> pg
  cron --> bvol[(Backup volume)]
  g1 & g2 & g3 & g4 -->|OAuth| oauth[OpenShift OAuth server]
  g1 & g2 & g3 & g4 -->|PromQL| thanos[Thanos / Prometheus<br/>of each cluster]
```

PostgreSQL is drawn in zone B as an example: it runs in either data zone and
moves with its volume.

| Concern | Design |
|---|---|
| State | Everything (dashboards, folders, users, permissions, alert rules, sessions) in PostgreSQL. Grafana pods are stateless: `/var/lib/grafana` is an emptyDir used as a cache. |
| Availability of Grafana | 4 replicas, 2 per data zone (soft zone spread), one per node (hard), PodDisruptionBudget `maxUnavailable: 1`, rolling updates with `maxUnavailable: 0`, a 10 s pre-stop drain. |
| Availability of PostgreSQL | One instance on a volume replicated by the storage layer. If its node fails, the pod restarts elsewhere with the same data. No PodDisruptionBudget, so node drains (cluster upgrades) are never blocked. |
| Zones | Required node affinity to the two data zones for every workload; the quorum zone never runs any of them. |
| Alerting | Unified alerting in HA mode: replicas share silences and notification state over the headless service (gossip on 9094). |
| Login | Grafana generic OAuth against the OpenShift OAuth server; groups mapped to Admin, Editor or Viewer. Local `admin` kept as break-glass. |
| Sharing | Anonymous access as Viewer on the main organisation; a folder is public when the Viewer role can see it. |
| Datasources | Provisioned from `values-local.yaml` with fixed uids. Adding one rolls the replicas one by one; nothing is lost. |

## Failure behaviour

| Event | Effect on users | Recovery |
|---|---|---|
| One Grafana pod killed | None measurable (tested: 0 failed requests out of 458) | Replaced by the Deployment in seconds |
| Every Grafana pod deleted at once | Unavailable until the first new pod is ready (about 20 s) | Content intact: it is in PostgreSQL |
| One node lost | Its Grafana replica moves; the other 3 serve | Automatic |
| One data zone lost | The 2 replicas of the other zone keep serving; the lost ones are recreated in the remaining zone (tested by draining a zone: 0 failed requests out of 607) | Automatic; replicas rebalance when the zone returns |
| PostgreSQL node lost | Grafana returns errors until PostgreSQL restarts on another node: about 1-2 minutes, plus up to 5 minutes for the node to be declared lost | Automatic, data intact (replicated volume) |
| Database corrupted or bad change | Content wrong | `scripts/db-restore.sh` from a daily dump |
| Cluster lost | Service lost | Redeploy elsewhere, restore a dump copied off-cluster |

## Why not...

- **SQLite on a volume**: a single writer; several replicas cannot share it,
  and losing the pod's volume loses everything. It is the cause of the original
  problem (dashboards lost on restart).
- **An operator for PostgreSQL** (CloudNativePG, Crunchy): would give streaming
  replication and faster failover, but adds an operator to install and run.
  Excluded by requirement. An external managed PostgreSQL can be used instead
  by pointing `grafana.ini [database]` at it and not deploying the base.
- **oauth-proxy sidecar**: would force a login on every request and make
  anonymous sharing impossible.
- **"Share externally" (public dashboards)**: does not support template
  variables or repeated rows, so the existing dashboards render empty.
