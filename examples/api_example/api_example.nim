import std/options
import chronos, results, confutils, confutils/defs
import waku

type CliArgs = object
  ethRpcEndpoint* {.
    defaultValue: "", desc: "ETH RPC Endpoint, if passed, RLN is enabled"
  .}: string

proc periodicSender(w: Waku): Future[void] {.async.} =
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

    counter += 1
    await sleepAsync(30.seconds)

when isMainModule:
  let args = CliArgs.load()

  echo "Starting Waku node..."

  let config =
    if (args.ethRpcEndpoint == ""):
      # Create a basic configuration for the Waku node
      # No RLN as we don't have an ETH RPC Endpoint
      NodeConfig.init(
        protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 42)
      )
    else:
      # Connect to TWN, use ETH RPC Endpoint for RLN
      NodeConfig.init(mode = WakuMode.Core, ethRpcEndpoints = @[args.ethRpcEndpoint])

  # Create the node using the library API's createNode function
  let node = (waitFor createNode(config)).valueOr:
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
