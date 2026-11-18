import results, libp2p/crypto/crypto
import
  chronos,
  chronicles,
  libp2p/multiaddress,
  libp2p/protocols/connectivity/autonat/client,
  libp2p/protocols/connectivity/autonat/service

const AutonatCheckInterval = Opt.some(chronos.seconds(30))

proc getAutonatService*(rng: crypto.Rng): AutonatService =
  ## AutonatService request other peers to dial us back
  ## flagging us as Reachable or NotReachable.
  ## minConfidence is used as threshold to determine the state.
  ## If maxQueueSize > numPeersToAsk past samples are considered
  ## in the calculation.
  let autonatService = AutonatService.new(
    autonatClient = AutonatClient.new(),
    rng = rng,
    scheduleInterval = AutonatCheckInterval,
    askNewConnectedPeers = false,
    numPeersToAsk = 3,
    maxQueueSize = 3,
    minConfidence = 0.7,
  )

  proc reachabilityHandler(
      networkReachability: NetworkReachability,
      confidence: Opt[float],
      dialBackAddr: Opt[MultiAddress],
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if confidence.isSome():
      debug "Peer reachability status",
        networkReachability = networkReachability, confidence = confidence.get()

  discard autonatService.reachabilityObservers.add(reachabilityHandler)

  return autonatService
