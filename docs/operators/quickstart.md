# Quickstart: running a nwaku node

This guide helps you run a nwaku node with typical configuration.
It connects your node to the `waku.sandbox` fleet for bootstrapping
and enables discovery v5 for continuous peer discovery.
Only [`relay`](https://rfc.vac.dev/spec/11/) protocol is enabled.
For a more comprehensive overview,
see our [step-by-step guide](./overview.md).

## Option 1: run nwaku binary

*Prerequisites are the usual developer tools,
such as a C compiler, Make, Bash and Git.*

```bash
git clone --recurse-submodules https://github.com/waku-org/nwaku
cd nwaku
make logosdeliverynode
./build/logosdeliverynode \
  --dns-discovery:true \
  --dns-discovery-url:enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im \
  --discv5-discovery \
  --nat=extip:[yourpublicip] # or, if you are behind a nat: --nat=any
```

## Option 2: run nwaku in a Docker container

*Prerequisite is a [Docker installation](./docker-quickstart.md#prerequisites).*

```bash
docker run -i -t -p 60000:60000 -p 9000:9000/udp \
  wakuorg/nwaku:v0.20.0 \ # or, the image:tag of your choice
    --dns-discovery:true \
    --dns-discovery-url:enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im \
    --discv5-discovery \
    --nat:extip:[yourpublicip] # or, if you are behind a nat: --nat=any
```

## Option 3: run nwaku with docker compose

*Prerequisites: `docker` and `docker-compose`*.
Allows to run `nwaku` with `prometheus` and `grafana`, with an already provisioned dashboard, in a few simple steps.
See [nwaku-compose](https://github.com/waku-org/nwaku-compose).

```bash
git clone https://github.com/waku-org/nwaku-compose
cd nwaku-compose
docker-compose up -d
```

Go to [http://localhost:3000/d/yns_4vFVk/nwaku-monitoring?orgId=1](http://localhost:3000/d/yns_4vFVk/nwaku-monitoring?orgId=1) and after some seconds, your node metrics will be live there.
As simple as that.

## Tips and tricks

To find the public IP of your host,
you can use

```bash
dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | awk -F'"' '{ print $2}'
```
