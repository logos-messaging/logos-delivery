import waku/waku_enr/capabilities, waku/waku_rendezvous/waku_peer_record

type GetShards* = proc(): seq[uint16] {.closure, gcsafe, raises: [].}

type GetCapabilities* = proc(): seq[Capabilities] {.closure, gcsafe, raises: [].}

type GetWakuPeerRecord* = proc(): WakuPeerRecord {.closure, gcsafe, raises: [].}
