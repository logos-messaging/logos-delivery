{.push raises: [].}

import
  results, nimcrypto/sha2, libp2p/protocols/pubsub, libp2p/protocols/pubsub/rpc/messages

## Message ID provider

type MessageIdProvider* = pubsub.MsgIdProvider

## Default message ID provider
# Performs a sha256 digest on the Waku Relay message payload. As Protocol Buffers v3
#  deterministic serialization is not canonical between the different languages and
#  implementations.
#
# See: https://gist.github.com/kchristidis/39c8b310fd9da43d515c4394c3cd9510
#
# This lack of deterministic serializaion could lead to a situation where two
# messages with the same attributes and serialized by different implementations
# have a different message ID (hash). This can impact the performance of the
# Waku Relay (Gossipsub) protocol's message cache and the gossiping process, and
# as a consequence the network.

proc defaultMessageIdProvider*(
    message: messages.Message
): Result[MessageID, ValidationResult] =
  let hash = sha256.digest(message.data)
  ok(@(hash.data))

## Waku message Unique ID provider
# TODO: Add here the MUID provider once `meta` field RFC PR is merged
