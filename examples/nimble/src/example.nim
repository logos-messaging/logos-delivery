import chronos, results
import waku

proc main() {.async.} =
  echo("Starting Waku node...")

  # Create a basic configuration for the Waku node
  # No RLN so we don't need to path an eth rpc endpoint
  let config = NodeConfig.init(
    protocolsConfig = ProtocolsConfig.init(entryNodes = @[], clusterId = 42)
  )

  # Create the node using the library API's createNode function
  let node = (await createNode(config)).valueOr:
    echo("Failed to create node: ", error)
    quit(1)

  echo("Waku node created successfully!")

  # Start the node
  (await startWaku(addr node)).isOkOr:
    echo("Failed to start node: ", error)
    quit(1)

  echo("Node started successfully! exiting")

when isMainModule:
  waitFor main()
