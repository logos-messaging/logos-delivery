## Node configuration for tests. The shipped defaults suit a deployed node, not
## a test process: nodes in one process share the working directory, so storage
## stays in memory, and no test node should look for a real NAT gateway, so NAT
## discovery is off. Override the returned configuration for anything else.

import std/net, results
import
  logos_delivery/api/conf/messaging_conf,
  logos_delivery/waku/persistency/persistency,
  tools/confutils/cli_args

export cli_args

const TestClusterId* = 3'u16

proc defaultTestWakuNodeConf*(
    mode = LogosDeliveryMode.Core,
    numShards: uint16 = 1,
    entryLayer = EntryLayer.channels,
    rest = false,
): WakuNodeConf =
  var conf = MessagingClientConf().toWakuNodeConf(mode).valueOr:
      raiseAssert error
  conf.entryLayer = entryLayer
  conf.listenAddress = parseIpAddress("0.0.0.0")
  conf.tcpPort = Port(0)
  conf.discv5UdpPort = Port(0)
  conf.clusterId = Opt.some(TestClusterId)
  conf.numShardsInNetwork = numShards
  conf.nat = "none"
  conf.localStoragePath = InMemoryStoragePath
  conf.rest = rest
  conf.restAddress = parseIpAddress("127.0.0.1")
  conf.restPort = 0'u16 # bind to an ephemeral port
  return conf
