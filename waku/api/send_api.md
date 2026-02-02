# SEND API

**THIS IS TO BE REMOVED BEFORE PR MERGE**

This document collects logic and todo's around the Send API.

## Overview

Send api hides the complex logic of using raw protocols for reliable message delivery.
The delivery method is chosen based on the node configuration and actual availabilities of peers.

## Delivery task

Each message send request is bundled into a task that not just holds the composed message but also the state of the delivery.

## Delivery methods

Depending on the configuration and the availability of store client protocol + actual configured and/or discovered store nodes:
- P2PReliability validation - checking network store node whether the message is reached at least a store node.
- Simple retry until message is propagated to the network
  - Relay says >0 peers as publish result
  - LightpushClient returns with success

Depending on node config:
- Relay
- Lightpush

These methods are used in combination to achieve the best reliability.
Fallback mechanism is used to switch between methods if the current one fails.

Relay+StoreCheck -> Relay+simple retry -> Lightpush+StoreCheck -> Lightpush simple retry -> Error

Combination is dynamically chosen on node configuration. Levels can be skipped depending on actual connectivity.
Actual connectivity is checked:
- Relay's topic health check - at least dLow peers in the mesh for the topic
- Store nodes availability - at least one store service node is available in peer manager
- Lightpush client availability - at least one lightpush service node is available in peer manager

## Delivery processing

At every send request, each task is tried to be delivered right away.
Any further retries and store check is done as a background task in a loop with predefined intervals.
Each task is set for a maximum number of retries and/or maximum time to live.

In each round of store check and retry send tasks are selected based on their state.
The state is updated based on the result of the delivery method.
