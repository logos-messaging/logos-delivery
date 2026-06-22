## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.

{.push raises: [].}

# WakuMessage was elevated to logos_delivery/api/types; re-exported here so
# existing call sites are unaffected.
from logos_delivery/api/types import WakuMessage
export WakuMessage

const MaxMetaAttrLength* = 64 # 64 bytes
