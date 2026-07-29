# Monitor nwaku using Prometheus and Grafana

## Prerequisites

1. A running nwaku instance with HTTP metrics server enabled (i.e. with `--metrics-server:true`)
2. [Prometheus](https://prometheus.io/) and [Grafana](https://grafana.com/) installed

### Installing Prometheus

Prometheus can be installed by downloading and extracting
the latest release for your system distribution from the [Prometheus download page](https://prometheus.io/download/).

For example, on a DebianOS distribution you could run

```bash
wget https://github.com/prometheus/prometheus/releases/download/v2.38.0/prometheus-2.38.0.linux-amd64.tar.gz
tar xvfz prometheus-2.38.0.linux-amd64.tar.gz
```

For more advanced installations,
Prometheus has a handy [Getting Started](https://prometheus.io/docs/prometheus/latest/getting_started/) page to guide you through the process.
There are also many third party guides on installing Prometheus for specific distributions,
such as [this old but still relevant one](https://www.digitalocean.com/community/tutorials/how-to-install-prometheus-on-ubuntu-16-04) from DigitalOcean.
We also suggest running Prometheus as a service,
as explained by [this guide](https://www.devopsschool.com/blog/how-to-run-prometheus-server-as-a-service/).
Bear in mind that we'll be creating our own `prometheus.yml` configuration file later on when you encounter this in any of the guides.

### Installing Grafana

Follow the [installation instructions](https://grafana.com/docs/grafana/latest/setup-grafana/installation/) appropriate to your distribution to install Grafana.
The stable version of the Grafana Enterprise Edition is the free, recommended edition to install.

## Configure Prometheus

1. Create a file called `prometheus.yml` with the following content:

```yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'nwaku'
    scrape_interval: 1s
    static_configs:
      - targets: ['localhost:<nwaku_port>']
```

Replace `<nwaku_port>` with the metrics HTTP server port of your running nwaku instance.
For default configurations metrics are reported on port `8008` of the `localhost`.
If you've used `--ports-shift`, or explicitly set the metrics port using `--metrics-server-port`, this port will be different from the default.
It's possible to extract the metrics server port from the startup logs of the nwaku node.
Look for a log with the format below and substitute `nwaku_port` with the value reported after `serverPort=`:

```
INF 2022-09-16 12:14:12.739+01:00 Metrics HTTP server started                topics="wakunode.setup.metrics" tid=6243 file=wakunode2_setup_metrics.nim:29 serverIp=127.0.0.1 serverPort=8009
```

2. Start Prometheus using the config file you created above:

```bash
./path/to/prometheus --config.file=/path/to/prometheus.yml &
```

3. Verify that Prometheus is running correctly.

Once Prometheus is running, it exposes by default a management console on port `9090`.
If you are running Prometheus locally, for example,
you can visit http://localhost:9090/ in a browser to view basic info about the running instance.
http://localhost:9090/targets shows the state of the different metrics server endpoints that we configured in `prometheus.yml`.
In our case we'd expect Prometheus to successfully scrape metrics off two endpoints,
the running nwaku instance and Prometheus itself.

## Configure Grafana

1. Start the Grafana server, if it's not running already after installation.

```bash
sudo systemctl start grafana-server
```

2. Open Grafana in your browser.

Grafana exposes its interface by default on port `3000`.
For example, if you are running Grafana locally,
you can find it by navigating to http://localhost:3000/.
If you are prompted for a username and password,
the default is `admin` in both cases.

3. Set Prometheus as your data source.

[These instructions](https://grafana.com/docs/grafana/latest/datasources/add-a-data-source/) describe how to add a new data source.
The default values for setting up a Prometheus data source should be sufficient.

4. Create a new dashboard or import an existing one.

You can now visualize metrics off your running nwaku instance by [creating a new dashboard and adding panels](https://grafana.com/docs/grafana/latest/dashboards/add-organize-panels/) for the metric(s) of your choice.
To get you started,
we have published a [basic monitoring dashboard for a single nwaku node](https://github.com/status-im/nwaku/blob/d4e899fba77389d20ca19c73a9443501039cdef2/metrics/waku-single-node-dashboard.json)
which you can [import to your Grafana instance](https://grafana.com/docs/grafana/latest/dashboards/manage-dashboards/#import-a-dashboard).

5. Happy monitoring!

Some of the most important metrics to keep an eye on include:
- `libp2p_peers` as an indication of how many peers your node is connected to,
- `logos_delivery_node_messages_total` to view the total amount of network traffic relayed by your node and
- `logos_delivery_node_errors` as a rough indication of basic operating errors logged by the node.

## Metric names

Every metric exported by the node is prefixed with `logos_delivery_`.
Metrics coming from libraries the node builds on (`libp2p_*`, `nim_gc_*`, `process_*`)
keep their own names and are unaffected.

Nodes before this rename exported the same metrics under a `waku_` prefix (and a few
under no prefix at all, such as `query_count` or `event_loop_load`). The dashboards in
[`metrics/`](https://github.com/logos-messaging/logos-delivery/tree/master/metrics) query
both spellings, so they keep working across the upgrade and over historical data:

```
(waku_store_queries_total or logos_delivery_store_queries_total)
```

Place the `or` around the leaf, inside any aggregation — not around the whole
expression. `or` keeps its right operand only for label sets that are absent from the
left, so this undercounts while a fleet is mid-upgrade:

```
sum by (type)(waku_node_errors_total) or sum by (type)(logos_delivery_node_errors_total)
```

Both sides collapse to the same label set, so the right one is discarded entirely and
every already-upgraded node vanishes from the panel. Write this instead:

```
sum by (type)(waku_node_errors_total or logos_delivery_node_errors_total)
```

When the metric sits inside a range vector, duplicate the whole call —
`(rate(old[5m]) or rate(new[5m]))` — since `(old or new)[5m]` is not valid PromQL.

If you maintain your own dashboards, alert rules or recording rules, apply the same
change before upgrading. Once every node you scrape runs a release with the new names
and the old samples have aged out of your Prometheus retention window, the `waku_`
alternative can be dropped.

