{.push raises: [].}

## Node lifecycle stage events.
##
## Emitted by the `Waku` factory object so loosely-coupled components
## (discovery backends, monitors) can react to node state changes without
## being wired into the start/stop code paths.

import brokers/event_broker

export event_broker

type NodeLifecycleStage* {.pure.} = enum
  Initialized ## conf resolved, WakuNode constructed (end of Waku.new)
  Starting ## Waku.start entered; DNS bootstrap retrieval about to run
  Started ## node started, dynamic bootstrap known, protocols mounted
  Stopping ## Waku.stop entered
  Stopped ## everything torn down

EventBroker:
  type NodeLifecycleEvent* = object
    stage*: NodeLifecycleStage
