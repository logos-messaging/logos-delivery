import
  chronos,
  chronicles,
  bearssl/rand,
  libp2p/protocols/connectivity/autonat/client,
  libp2p/protocols/connectivity/autonat/service

const AutonatCheckInterval = Opt.some(chronos.seconds(30))

proc getAutonatService*(rng: ref HmacDrbgContext): AutonatService =
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

  proc statusAndConfidenceHandler(
      networkReachability: NetworkReachability, confidence: Opt[float]
  ): Future[void] {.gcsafe, async: (raises: [CancelledError]).} =
    if confidence.isSome():
      info "Peer reachability status",
        networkReachability = networkReachability, confidence = confidence.get()

  autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

  return autonatService
