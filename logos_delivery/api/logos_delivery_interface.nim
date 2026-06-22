## LogosDeliveryInterface — the facade / mainClass interface.
##
## Owns the node and the three sub-interfaces; getters return them. This module
## imports AND re-exports the three sub-interface contracts so a consumer can
## `import ./LogosDeliveryInterface` and get the whole interface surface.

import results, chronos
import brokers/broker_interface

# Module aliases avoid the module-name vs type-name clash (file KernelInterface.nim
# exports type KernelInterface); the type names stay in scope unqualified for the getters.
import ./kernel_interface as ikernel_iface
import ./messaging_client_interface as imessagingclient_iface
import ./reliable_channel_manager_interface as ireliablechannelmanager_iface

export ikernel_iface, imessagingclient_iface, ireliablechannelmanager_iface

BrokerInterface(LogosDeliveryInterface):
  EventBroker:
    type ConnectionStatusChangeEvent* = object
      connectionStatus*: ConnectionStatus

  RequestBroker:
    proc startAsNode(config: string): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc startAsClient(
      mode: WakuMode, preset: string
    ): Future[Result[MessagingClientInterface, string]] {.async.}

  RequestBroker:
    proc shutdown(): Future[Result[void, string]] {.async.}

  RequestBroker:
    proc stop(): Future[Result[void, string]] {.async.}

  RequestBroker:
    # Getters: return the owned sub-interface instances.
    proc kernel(): Future[Result[KernelInterface, string]] {.async.}

  RequestBroker:
    proc messaging(): Future[Result[MessagingClientInterface, string]] {.async.}

  RequestBroker:
    proc channels(): Future[Result[ReliableChannelManagerInterface, string]] {.async.}

  RequestBroker:
    proc getNodeInfo(id: NodeInfoId): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc getAvailableConfigs(): Future[Result[string, string]] {.async.}
