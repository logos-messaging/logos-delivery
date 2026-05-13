import brokers/multi_request_broker

# Teardown Request for loose coupled components.
# Note: This is a multi request - and not an event - due it is waitable, as such
# makes shutdown processing more deterministic (unlike event might be in-flight while we already shutdown).
MultiRequestBroker:
  type Teardown* = object
    component*: string # for logging purposes
