import chronos
import logos_delivery

proc shortenIntervals*(node: LogosDelivery) =
  ## Shortens the receive, send and edge filter intervals of a node not started yet.
  node.messagingClient.recvService.delayExtra = 1.seconds
  node.messagingClient.recvService.archiveTime = 1.seconds
  node.messagingClient.recvService.timestampVariance = 1.seconds
  node.messagingClient.recvService.activityWriteInterval = 500.milliseconds
  node.messagingClient.sendService.archiveTime = 300.milliseconds
  # A shorter interval would exceed a filter service's 30 requests per minute
  # per peer, and a peer that rejects the loop's request is removed.
  node.waku.node.subscriptionManager.edgeFilterLoopInterval = 2.seconds
  node.waku.node.subscriptionManager.edgeFilterSubLoopDebounce = 50.milliseconds
