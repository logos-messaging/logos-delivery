import std/options
import chronos, results, confutils, confutils/defs
import waku

type CliArgs = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string

proc periodicSender(w: Waku): Future[void] {.async.} =
  let sentListener = MessageSentEvent.listen(
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      echo "Message sent with request ID: ",
        event.requestId, " hash: ", event.messageHash
  ).valueOr:
    echo "Failed to listen to message sent event: ", error
    return

  let errorListener = MessageSendErrorEvent.listen(
    proc(event: MessageSendErrorEvent) {.async: (raises: []).} =
      echo "Message failed to send with request ID: ",
        event.requestId, " error: ", event.error
  ).valueOr:
    echo "Failed to listen to message send error event: ", error
    return

  let propagatedListener = MessageSendPropagatedEvent.listen(
    proc(event: MessageSendPropagatedEvent) {.async: (raises: []).} =
      echo "Message propagated with request ID: ",
        event.requestId, " hash: ", event.messageHash
  ).valueOr:
    echo "Failed to listen to message send propagated event: ", error
    return

  defer:
    MessageSentEvent.dropListener(sentListener)
    MessageSendErrorEvent.dropListener(errorListener)
    MessageSendPropagatedEvent.dropListener(propagatedListener)

  ## Periodically sends a Waku message every 30 seconds
  var counter = 0
  while true:
    let envelope = MessageEnvelope.init(
      contentTopic = "example/content/topic",
      payload = "Hello Waku! Message number: " & $counter,
    )

    let sendRequestId = (await w.send(envelope)).valueOr:
      echo "Failed to send message: ", error
      quit(QuitFailure)

    echo "Sending message with request ID: ", sendRequestId, " counter: ", counter

    counter += 1
    await sleepAsync(30.seconds)

when isMainModule:
  let args = CliArgs.load()

  echo "Starting Waku node..."

  # Use WakuNodeConf (the CLI configuration type) for node setup
  var conf = defaultWakuNodeConf().valueOr:
    echo "Failed to create default config: ", error
    quit(QuitFailure)

  if args.ethRpcEndpoint == "":
    # Create a basic configuration for the Waku node
    # No RLN as we don't have an ETH RPC Endpoint
    conf.mode = Core
    conf.preset = "logos.dev"
  else:
    # Connect to TWN, use ETH RPC Endpoint for RLN
    conf.mode = Core
    conf.preset = "twn"
    conf.ethClientUrls = @[EthRpcUrl(args.ethRpcEndpoint)]

  # Create the node using the library API's createNode function
  let node = (waitFor createNode(conf)).valueOr:
    echo "Failed to create node: ", error
    quit(QuitFailure)

  echo("Waku node created successfully!")

  # Start the node
  (waitFor startWaku(addr node)).isOkOr:
    echo "Failed to start node: ", error
    quit(QuitFailure)

  echo "Node started successfully!"

  asyncSpawn periodicSender(node)

  runForever()
