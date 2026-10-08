# Plugins

Grafana's built-in panels and datasources cover most dashboards. This
deployment adds two plugins, both made and signed by Grafana Labs:

| Plugin | Version | Why |
|---|---|---|
| `grafana-polystat-panel` | 2.1.16 | Shows one hexagon per item, coloured by status, with a link to the detail. It suits a fleet overview with one hexagon per cluster. |
| `grafana-metricsdrilldown-app` | 2.5.1 | Lets people browse Prometheus metrics and labels without writing PromQL. It only reads datasources that already exist. |

## How they get into the pods

The clusters cannot reach grafana.com, and Grafana runs from the official
image without any rebuild. The plugins therefore travel with the repository and
go through a shared volume:

1. `plugins/` holds the plugin archives, as published on the plugins' GitHub
   release pages. `values/plugins.lock` lists each one with its version, the
   SHA-256 of the archive and where it came from.
2. `scripts/load-plugins.sh` checks every archive against its SHA-256, unpacks
   it on the deployment machine, and copies the result with `oc cp` to the
   volume `grafana-plugins`. It does this through a short-lived pod that runs
   in a data zone with the PostgreSQL image the deployment already uses. The
   new set replaces the old one in a single rename, and the previous set stays
   on the volume as `live.old`. The script records the loaded set in the
   ConfigMap `grafana-plugins`.
3. When a Grafana pod starts, the init container `copy-plugins` copies the
   current set from the volume into the pod (an emptyDir mounted at
   `/opt/grafana/plugins`). Grafana reads its plugins there.

Running pods never read the shared volume, so a storage incident affects only
pods that start during it. Such a pod waits in its init container, and the
other replicas keep serving.

`install.sh` refuses to deploy if the set on the volume does not match
`values/plugins.lock`, and it puts the set's identifier in a pod annotation, so
loading a new set and running `install.sh --apply` restarts the replicas one
at a time.

The volume `grafana-plugins` is a ReadWriteMany PVC of a few MiB, of the class
`PLUGINS_STORAGE_CLASS` in `deploy.env` (for example a Portworx class with
`sharedv4: "true"`). `collect-facts.sh target` counts the candidate classes.

Grafana makes no plugin download at start (`preinstall_disabled`) and checks
plugin signatures with the key built into it (`public_key_retrieval_disabled`),
so it makes no call to grafana.com.

## Adding or upgrading a plugin

1. Check that the plugin is signed by Grafana Labs or a known vendor, works
   with the Grafana version in use (its `grafanaDependency` on grafana.com), and
   is built with React. Angular plugins no longer load in Grafana 12 and later.
2. Download the release archive on a machine with Internet access, for
   example from the plugin's GitHub release page or from
   `https://grafana.com/api/plugins/<id>/versions/<version>/download`.
3. Save it as `plugins/<id>-<version>.zip`, remove the old archive, and update
   the line in `values/plugins.lock` with the version, the SHA-256
   (`sha256sum <file>`) and the source URL.
4. Push the change from a machine that can push to GitHub. CI starts the
   official Grafana image with the plugins and checks that each one loads,
   signed, at its version.
5. Run the local test (T15 checks the versions on every replica), then on the
   cluster run `scripts/load-plugins.sh --apply` and `scripts/install.sh --apply`.

To go back to the previous set, restore the previous `plugins/` and
`values/plugins.lock` from Git and run the same two commands.

Anonymous users can open any panel plugin and query every datasource. A plugin
that adds a datasource able to call arbitrary URLs, such as Infinity, needs a
strict list of allowed hosts.
