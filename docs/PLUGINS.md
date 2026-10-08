# Plugins

Grafana's built-in panels and datasources cover most dashboards. This
deployment adds two plugins, both made and signed by Grafana Labs:

| Plugin | Version | Why |
|---|---|---|
| `grafana-polystat-panel` | 2.1.16 | Shows one hexagon per item, coloured by status, with a link to the detail. It suits a fleet overview with one hexagon per cluster. |
| `grafana-metricsdrilldown-app` | 2.5.1 | Lets people browse Prometheus metrics and labels without writing PromQL. It only reads datasources that already exist. |

## How they get into the cluster

The clusters cannot reach grafana.com, so the plugins travel with the
repository and are baked into the Grafana image:

- `image/plugins/` holds the plugin archives, as published on the plugins'
  GitHub release pages.
- `values/plugins.lock` lists each plugin with its version, the SHA-256 of its
  archive and where it came from.
- `image/Dockerfile` adds the unpacked plugins to the official Grafana image,
  in `/opt/grafana/plugins`.
- `scripts/build-image.sh` checks every archive against its SHA-256, unpacks
  them, and builds the image in the target namespace with an OpenShift binary
  build. The result goes to the internal registry as `grafana:<tag>`. The tag
  comes from a hash of the Dockerfile and the lock file, so it changes only
  when they change.
- `scripts/install.sh` deploys that image by digest.

Grafana makes no plugin download at start (`preinstall_disabled`) and checks
plugin signatures with the key built into it (`public_key_retrieval_disabled`),
so it makes no call to grafana.com.

The build needs the internal image registry (`Managed`), the Build API, and the
right to create Docker-strategy builds in the namespace. `collect-facts.sh
target` reports all three. The build pod runs in the first data zone, never in
the quorum zone.

## Adding or upgrading a plugin

1. Check that the plugin is signed by Grafana Labs or a known vendor, works
   with the Grafana version in use (its `grafanaDependency` on grafana.com), and
   is built with React. Angular plugins no longer load in Grafana 12 and later.
2. Download the release archive on a machine with Internet access, for
   example from the plugin's GitHub release page or from
   `https://grafana.com/api/plugins/<id>/versions/<version>/download`.
3. Save it as `image/plugins/<id>-<version>.zip`, remove the old archive, and
   update the line in `values/plugins.lock` with the version, the SHA-256
   (`sha256sum <file>`) and the source URL.
4. Push the change from a machine that can push to GitHub. CI builds the image
   and checks that every plugin loads, signed, at its version.
5. Run the local test (T15 checks the versions on every replica), then on the
   cluster run `scripts/build-image.sh --apply` and `scripts/install.sh --apply`.

Anonymous users can open any panel plugin and query every datasource. A plugin
that adds a datasource able to call arbitrary URLs, such as Infinity, needs a
strict list of allowed hosts.
