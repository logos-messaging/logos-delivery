# API design and consistency

Users need to be able to run a Delivery node, run their own fleets, or join existing networks, or simply send and receive messages over existing network. 

We have a few APIs: CLI, library (nim / C-bindings), REST. We should define which API is for which use case, and which API should support which features.

There's been a few discussions about this, e.g.:
- https://github.com/logos-messaging/logos-delivery/issues/3795
- https://github.com/logos-messaging/logos-delivery/pull/3828
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4317261531
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4337495581
  - https://github.com/logos-messaging/logos-delivery/pull/3828#issuecomment-4353802313
- https://github.com/logos-co/logos-delivery-module/issues/18

I would like us to come up to an agreement and implement it.

## User roles

There're 3 main roles of `logos-delivery` users, which we need to cover:
1. Node Operator
    - Run a custom node (== run a fleet node)
    - Join existing network
2. App developer
    - Send/Receive messages on existing network
3. Tester
    - Run a custom node
    - Instruct the node to Send/Receive messages with certain protocols

## Ways to configure a node

1. CLI
2. Library API
3. Logos Core (effectively same as [2])

## User journeys

### I am developing an application and want to send/receive messages over Logos Testnet

This should be done with Messaging API, i.e. a high-level API, which hides all complexity and customization.

| Parameter | Value |
|-|-|
| preset | `logos.test` |
| mode | Core / Edge |

### I want to run a node 24/7 to support Logos Testnet

| Parameter | Value |
|-|-|
| preset | `logos.test` |
| nat | ... |
| relay, lightpush, store | ... |

### I need to host a fleet of custom configuration nodes for my own network

In this case, user should manually configure all of the parameters:
- Network: cluster id, number of shards in network, max message size
- Connectivity: nat, external addresses
- Protocols: relay, lightpush, store
- RLN configuration: cred path, eth client address, chain id, etc.

| Parameter | Value |
|-|-|
| cluster id, number of shards in network, max message size | |
| nat | ... |
| relay, lightpush, store | ... |

> [!NOTE]
> No use of `preset`, only explicit list of parameters
> 
> **Q:** Why can't we use `preset` in this case?
> **A:** Node should be configurable by Infra, not by changing `logos-delivery` source code, rebuilding and re-deploying.

## API

1. CLI
2. Library (Nim, C-bindings)
3. REST API (to be deprecated, use Logos Core module API instead, exposed to REST or Python)

### Logos Core

Ideally, in all use cases, Logos Core with `logos-delivery-module` should be used. Not CLI, not REST API. 
This means that Library itself should expose enough API.

So probably `createNode` should have 2 signatures: `createNode(preset, mode)` and `createNode(config)` (I think it's already like this).

### CLI

But for now (and amybe forever), we'll need to keep supporting CLI. It needs to be cleaned up. Options like `--mode` should not appear there, because `mode` is a notion of Messaging API, while CLI doesn't expose Messaging API capabilities.