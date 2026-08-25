## One crossing to the process that owns the libp2p node: an op name, a JSON
## argument object, and a JSON answer.

{.push raises: [].}

import std/json, results, chronos

type NetTransport* = ref object of RootObj

method submit*(
    transport: NetTransport, op: string, args: JsonNode, timeout: Duration
): Future[Result[JsonNode, string]] {.base, async: (raises: []).} =
  raiseAssert "[NetTransport.submit] abstract method not implemented"

{.pop.}
