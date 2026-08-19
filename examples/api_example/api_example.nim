import chronos, results, confutils, confutils/defs
import logos_delivery

type CliArgs = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string

proc periodicSender(logos: LogosDelivery): Future[void] {.async.} =
  let sentListener = MessageSentEvent.listen(
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      echo "Message sent with request ID: ",
        event.requestId, " hash: ", event.messageHash
  ).valueOr:
    echo "Failed to listen to message sent event: ", error
    return

  let errorListener = MessageErrorEvent.listen(
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      echo "Message failed to send with request ID: ",
        event.requestId, " error: ", event.error
  ).valueOr:
    echo "Failed to listen to message error event: ", error
    return

  let propagatedListener = MessagePropagatedEvent.listen(
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      echo "Message propagated with request ID: ",
        event.requestId, " hash: ", event.messageHash
  ).valueOr:
    echo "Failed to listen to message propagated event: ", error
    return

  defer:
    await MessageSentEvent.dropListener(sentListener)
    await MessageErrorEvent.dropListener(errorListener)
    await MessagePropagatedEvent.dropListener(propagatedListener)

  ## Periodically sends a Waku message every 30 seconds
  var counter = 0
  while true:
    let envelope = MessageEnvelope.init(
      contentTopic = "example/content/topic",
      payload = "Hello Waku! Message number: " & $counter,
    )

    let sendRequestId = (await logos.messagingClient.send(envelope)).valueOr:
      echo "Failed to send message: ", error
      quit(QuitFailure)

    echo "Sending message with request ID: ", sendRequestId, " counter: ", counter

    counter += 1
    await sleepAsync(30.seconds)

when isMainModule:
  let args = CliArgs.load()

  echo "Starting Waku node..."

  var preset: string
  var messagingOverrides = MessagingClientConf()
  if args.ethRpcEndpoint == "":
    # Create a basic configuration for the Waku node
    # No RLN as we don't have an ETH RPC Endpoint
    preset = "logos.dev"
  else:
    # Connect to TWN, use ETH RPC Endpoint for RLN
    preset = "twn"
    messagingOverrides.ethRpcEndpoints = Opt.some(@[EthRpcUrl(args.ethRpcEndpoint)])

  # Create the full Logos Messaging stack (Waku + messaging + channels)
  let node = (
    waitFor LogosDelivery.new(
      mode = LogosDeliveryMode.Core,
      preset = preset,
      messagingOverrides = messagingOverrides,
      channelsOverrides = ReliableChannelManagerConf(),
    )
  ).valueOr:
    echo "Failed to create node: ", error
    quit(QuitFailure)

  echo("Logos Messaging node created successfully!")

  # Start the node
  (waitFor node.start()).isOkOr:
    echo "Failed to start node: ", error
    quit(QuitFailure)

  echo "Node started successfully!"

  asyncSpawn periodicSender(node)

  runForever()
