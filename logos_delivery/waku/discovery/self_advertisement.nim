{.push raises: [].}

## Advertising this node on the kademlia service-discovery network.
##
## Every participating node registers interest in `/logos/delivery`, and a node
## that serves anything (relay, store, filter, lightpush) also advertises
## itself under it. That gives the network one place to look for its own
## members, instead of each node only being findable through whichever
## protocol-specific service it happens to run.
##
## Which backends take part is decided by what they declare, not by naming
## them: a backend receives this only if its `keyKinds` includes `svc`. That is
## true of both kademlia hosts -- in-process and plugin -- and false of discv5,
## whose advertising means mutating our own ENR and which rejects `svc:` keys
## outright.

import std/[algorithm, json, sequtils, strutils]
import chronos, chronicles, results
import
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/waku/waku_enr/capabilities

logScope:
  topics = "waku discovery advertise"

const git_version {.strdefine.} = "(unknown)"

const SvcKey = SvcKeyPrefix & LogosDeliveryServiceId

proc selfAdvertisementData*(conf: WakuConf, shards: seq[uint16]): seq[byte] =
  ## The payload published alongside the advertisement, as JSON.
  ##
  ## Experimental, so it is JSON rather than a codec: the shape is expected to
  ## move, and the external provider already hands us `data` as base64 JSON at
  ## its own boundary. `cluster` travels with `shards` because a shard index is
  ## meaningless without it.
  ## Shards are sorted so the same node produces the same record twice.
  ## `git_version` arrives from `-d:git_version=\"...\"`, quotes included, so
  ## they are stripped rather than nested inside the JSON string.
  let payload = %*{
    "version": git_version.strip(chars = {'"'}),
    "cluster": conf.clusterId,
    "shards": shards.sorted(),
    "protocols": conf.wakuFlags.toCodecs(),
  }
  return cast[seq[byte]]($payload)

proc advertiseSelf*(
    discoveries: seq[IPeerDiscovery], conf: WakuConf, shards: seq[uint16]
): Future[void] {.async: (raises: []).} =
  ## Registers interest in `/logos/delivery` on every service-capable backend,
  ## and advertises this node there when it serves something. `shards` is what
  ## the node is actually subscribed to -- the caller resolves that, since the
  ## configured list is not the same thing under autosharding.
  ##
  ## Best-effort per backend: a node whose discovery could not announce it is
  ## degraded, not broken, and the other backends should still get their turn.
  let serves = conf.wakuFlags.isServiceNode()
  let data =
    if serves:
      selfAdvertisementData(conf, shards)
    else:
      @[]

  for discovery in discoveries:
    let info = (await discovery.backendInfo()).valueOr:
      debug "skipping backend with unreadable info", reason = error
      continue

    if SvcKind notin info.keyKinds:
      continue

    (await discovery.registerInterest(SvcKey)).isOkOr:
      warn "could not register interest in the delivery network",
        backend = info.id, reason = error

    if not serves:
      continue

    (await discovery.startAdvertising(SvcKey, data, @[])).isOkOr:
      warn "could not advertise this node on the delivery network",
        backend = info.id, reason = error
      continue

    info "advertising this node on the delivery network",
      backend = info.id, protocols = conf.wakuFlags.toCodecs()
