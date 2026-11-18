# Examples

## Compile

Make all examples.
```console
make example2
```

## Logos Delivery API

Uses the simplified Logos Delivery API to create and start a node,
you need an RPC endpoint for Linea Sepolia for RLN:

```console
./build/api_example --ethRpcEndpoint=https://linea-sepolia.infura.io/v3/<your key>
```

If you can't be bothered but still want to see some action,
just run the binary and it will use a non-RLN network:

```console
./build/api_example
```

## publisher/subscriber

Within `examples/` you can find a `publisher` and a `subscriber`. The first one publishes messages to the default pubsub topic on a given content topic, and the second one runs forever listening to that pubsub topic and printing the content it receives.

**Some notes:**
* These examples are meant to work even if you are behind a firewall and you can't be discovered by discv5.
* You only need to provide a reachable bootstrap peer (see our [fleets](https://fleets.status.im/))
* The examples are meant to work out of the box.
* Note that both services wait for some time until a given minimum amount of connections are reached. This is to ensure messages are gossiped.

**Run:**

Wait until the subscriber is ready.
```console
./build/subscriber
```

And run a publisher
```console
./build/publisher
```

See how the subscriber received the messages published by the publisher. Feel free to experiment from different machines in different locations.

## resource-restricted publisher/subscriber (lightpush/filter)

To illustrate publishing and receiving messages on a resource-restricted client,
`examples/v2` also provides a `lightpush_publisher` and a `filter_subscriber`.
The `lightpush_publisher` continually publishes messages via a lightpush service node
to the default pubsub topic on a given content topic.
The `filter_subscriber` subscribes via a filter service node
to the same pubsub and content topic.
It runs forever, maintaining this subscription
and printing the content it receives.

**Run**
Start the filter subscriber.
```console
./build/filter_subscriber
```

And run a lightpush publisher
```console
./build/lightpush_publisher
```

See how the filter subscriber receives messages published by the lightpush publisher.
Neither the publisher nor the subscriber participates in `relay`,
but instead make use of service nodes to save resources.
Feel free to experiment from different machines in different locations.
