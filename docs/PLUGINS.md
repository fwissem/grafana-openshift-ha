# Plugins

Grafana's built-in panels and datasources cover most dashboards. This
deployment adds two plugins, both made by Grafana Labs:

| Plugin | Version | Why |
|---|---|---|
| `grafana-polystat-panel` | 2.1.16 | Shows one hexagon per item, coloured by status, with a link to the detail. It suits a fleet overview with one hexagon per cluster. |
| `grafana-metricsdrilldown-app` | 2.5.1 | Lets people browse Prometheus metrics and labels without writing PromQL. It only reads datasources that already exist. |

The list lives in two places that CI keeps identical:
`grafana.ini.plugins.preinstall_sync` in `values/values.yaml`, and
`values/plugins.lock`, which also holds the SHA-256 of each archive.

## How they are installed

The Grafana pods keep no disk, so each pod installs the plugins every time it
starts, before it serves any request. Every replica therefore runs the same
versions, and a version only changes when you change it in the repository.

If the download fails, that pod does not start. The other replicas keep
serving, and a rolling update stops at the first pod that cannot start. Check
the pod logs for `Failed to install plugin`.

By default the pods download from grafana.com. If they cannot reach it, use a
mirror:

1. On a machine with Internet access, run `scripts/fetch-plugins.sh`. It
   downloads each archive into `local/plugins/` and checks its SHA-256 against
   `values/plugins.lock`.
2. Upload the zip files, keeping their names (`<id>-<version>.zip`), to an
   internal web server or repository that the pods can reach.
3. Set `PLUGIN_MIRROR_URL` in `local/deploy.env` to the base URL of that
   location, then run `scripts/install.sh --check` and `--apply`.

## Plugins switched off

By default Grafana also downloads four app plugins at every start. They need
Loki, Tempo or Pyroscope, which this platform does not use, so
`disable_plugins` turns them off: `grafana-lokiexplore-app`,
`grafana-exploretraces-app`, `grafana-pyroscope-app` and `grafana-advisor-app`.
`preinstall_auto_update: false` stops Grafana from upgrading anything on its own.

## Adding or upgrading a plugin

1. Check that the plugin is signed by Grafana Labs or a known vendor, works
   with the Grafana version in use (its `grafanaDependency` on grafana.com), and
   is built with React. Angular plugins no longer load in Grafana 12 and later.
2. Add `id@version` to `preinstall_sync` in `values/values.yaml`, and a line
   with the id, version and SHA-256 to `values/plugins.lock`. The SHA-256 is
   shown by `https://grafana.com/api/plugins/<id>/versions/<version>` (package
   `any`).
3. If you use a mirror, run `scripts/fetch-plugins.sh` and upload the new zip.
4. Run the local test. Test T15 checks the versions on every replica. Then
   deploy with `scripts/install.sh`.

Remember that anonymous users can open any panel plugin and query every
datasource. A plugin that adds a datasource able to call arbitrary URLs, such
as Infinity, needs a strict list of allowed hosts.
