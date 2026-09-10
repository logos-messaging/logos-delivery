# Listening on Websocket to Enable Connections With Waku v2 Browser Peers

> TODO (2023-05-24): Deprecate or fix

Currently, nim-waku only supports TCP transport.
This means it is not possible to directly connect from a browser using [js-waku](https://github.com/waku-org/js-waku/)
to a nim-waku based node such as logosdeliverynode.

To remediate to this, utilities such as [websockify](https://github.com/novnc/websockify) can be used.
This tutorial explains how one can setup websockify alongside logosdeliverynode to accept connections from peer browsers.

Note that popular browsers only accept secure websocket connections (`wss`) in a secure page (`https`),
hence we will also cover the creation of SSL certificates.

## Creating certificate using cerbot 

Feel free to skip this step if you already own SSL certificate for your domain.

To do so, simply follow the instructions at https://certbot.eff.org/.

Note that you do not need to have a web server (e.g. apache, nginx) running to setup logosdeliverynode with websockify.

## Setting up websockify

You can install [Websockify](https://github.com/novnc/websockify) via your preferred package manager
or [using Python](https://github.com/novnc/websockify#installing-websockify).

To start websockify, use the following command:

```shell
sudo websockify \
--cert /etc/letsencrypt/live/<your.domain>/fullchain.pem \
--key /etc/letsencrypt/live/<your.domain>/privkey.pem 0.0.0.0:443 \
127.0.0.1:<tcp_port>
```

With:
- `your.domain` being your domain name (.e.g `www.example.org`).
- `tcp_port` being the port on which logosdeliverynode is listening, by default `60000`.

Notes:
- This assumes you used `certbot` to generate certificate, `/etc/letsencrypt/live` is where `certbot store certificates,
  if you have your own certificates, changes the path and be sure to pass the full certificate chain including
  the CA certificate to the `--cert` argument.
- `sudo` is needed because websockify listens on port `443`;
  You can avoid using `sudo` by using a custom port, just be sure it is open to the internet by checking your firewall.   

## Getting your logosdeliverynode's multiaddr

Start `logosdeliverynode` as you usually do,
be sure to take in account the listening port to reflect it in the websockify command line.

`logosdeliverynode` prints the multiaddr it is listening too at the start of the logs:

```
INF 2021-06-23 10:37:25.274+10:00 Listening on topics="wakunode" tid=2271871 file=logosdeliverynode.nim:170 full=/ip4/1.2.3.4/tcp/60000/p2p/16Uiu2HAmPRmVHjZSP3U1T9ez4EQBBUsji5RyvAyDGVNgTQajtEQJ
```

To get the websocket multiaddr, simply change the port and insert `wss` after said port:

```
/ip4/1.2.3.4/tcp/443/wss/p2p/16Uiu2HAmPRmVHjZSP3U1T9ez4EQBBUsji5RyvAyDGVNgTQajtEQJ
```

You can also use your domain name instead of ip address:

```
/dns4/your.domain/tcp/443/wss/p2p/16Uiu2HAmPRmVHjZSP3U1T9ez4EQBBUsji5RyvAyDGVNgTQajtEQJ
```
