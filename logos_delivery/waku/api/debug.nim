## Waku layer API — debug / info getters (all synchronous).
{.push raises: [].}

import metrics
import eth/p2p/discoveryv5/enr

import logos_delivery/waku/waku
import logos_delivery/waku/node/waku_node

proc version*(self: Waku): string =
  return WakuNodeVersionString

proc listenAddresses*(self: Waku): seq[string] =
  return self.node.info().listenAddresses

proc myEnr*(self: Waku): string =
  return self.node.enr.toURI()

proc myPeerId*(self: Waku): string =
  return $self.node.peerId()

proc metrics*(self: Waku): string =
  {.gcsafe.}:
    return defaultRegistry.toText()
