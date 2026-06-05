import
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  libp2p/protocols/connectivity/autonat/client,
  libp2p/protocols/connectivity/autonat/service

const AutonatCheckInterval = Opt.some(chronos.seconds(30))

proc getAutonatService*(rng: crypto.Rng): AutonatService =
  ## AutonatService request other peers to dial us back
  ## flagging us as Reachable or NotReachable.
  ## minConfidence is used as threshold to determine the state.
  ## If maxQueueSize > numPeersToAsk past samples are considered
  ## in the calculation.
  ##
  ## NOTE: After obtaining the service (and wrapping in HPService if using holepunch),
  ## the caller *must* call .setup(theSwitch) on it (or on the HPService) before adding
  ## to switch.services and calling switch.start(). This populates the addressMapper
  ## proc (and handlers) that autonat.start() assumes when enableAddressMapper (default).
  ## Direct assignment to switch.services (as done in factory + chat2disco) bypasses
  ## the deprecated switch.add() that used to auto-call setup. Missing setup + enable=true
  ## leads to adding a nil mapper and nil call during peerInfo.update inside switch.start
  ## (surfaces as SEGV at waku_node:589).
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
