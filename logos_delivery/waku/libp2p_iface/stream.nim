## Owned stream interface: what the request/response protocols need from an
## open libp2p stream.
##
## The stream error types of the contract are exported too: a stream raises
## `MaxSizeError` when a length-prefixed message exceeds the limit and
## `LPStreamError` (or a subtype, e.g. `LPStreamRemoteClosedError`) when the
## stream fails.
##
## `PeerId` is a plain value type (the multihash bytes) shared by the whole code
## base, so it is used as is; behaviour (reading, writing, closing) is expressed
## through the concept below.
{.push raises: [].}

import chronos
import libp2p/peerid
from libp2p/stream/lpstream import
  LPStreamError, MaxSizeError, LPStreamRemoteClosedError

export peerid, LPStreamError, MaxSizeError, LPStreamRemoteClosedError

type IStream* = concept s
  # Contract a stream must satisfy. The calls may raise (the underlying
  # transport can fail); protocols guard them with `catch`. Closing only
  # raises CancelledError, so a protocol can close from a `defer`.
  s.peerId is PeerId
  s.writeLP(seq[byte]) is Future[void]
  s.readLp(int) is Future[seq[byte]]
  s.close() is Future[void]
  s.closeWithEof() is Future[void]
  s.atEof() is bool
