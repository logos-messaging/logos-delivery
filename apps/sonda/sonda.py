import requests
import time
import json
import os
import base64
import sys
import urllib.parse
import requests
import argparse
from datetime import datetime
from prometheus_client import Counter, Gauge, start_http_server

# Content topic where Sona messages are going to be sent
SONDA_CONTENT_TOPIC = '/sonda/2/polls/proto'

# Prometheus metrics
successful_sonda_msgs = Counter('successful_sonda_msgs', 'Number of successful Sonda messages sent')
failed_sonda_msgs = Counter('failed_sonda_msgs', 'Number of failed Sonda messages attempts')
successful_store_queries = Counter('successful_store_queries', 'Number of successful store queries', ['node'])
failed_store_queries = Counter('failed_store_queries', 'Number of failed store queries', ['node', 'error'])
empty_store_responses = Counter('empty_store_responses', "Number of store responses without the latest Sonda message", ['node'])
store_query_latency = Gauge('store_query_latency', 'Latency of the last store query in seconds', ['node'])
consecutive_successful_responses = Gauge('consecutive_successful_responses', 'Consecutive successful store responses', ['node'])
node_health = Gauge('node_health', "Binary indicator of a node's health. 1 is healthy, 0 is not", ['node'])

# Bounded set of values for the 'error' label of failed_store_queries. A label must
# never hold a raw cause string: that is what blows up cardinality.
ERR_LOCAL_NODE_UNREACHABLE = 'local_node_unreachable'
ERR_PEER_UNREACHABLE = 'peer_unreachable'
ERR_QUERY_TIMEOUT = 'query_timeout'
ERR_STORE_BACKEND_ERROR = 'store_backend_error'
ERR_UNKNOWN = 'unknown'

# Store protocol status code -> error label. 300 (BAD_RESPONSE) is absent on purpose:
# it is the only status whose cause string has to be inspected to be classified.
STORE_STATUS_ERRORS = {
    504: ERR_PEER_UNREACHABLE,     # PEER_DIAL_FAILURE
    503: ERR_STORE_BACKEND_ERROR,  # SERVICE_UNAVAILABLE
    429: ERR_STORE_BACKEND_ERROR,  # TOO_MANY_REQUESTS: load shedding is store-side
}


# Argparser configuration
parser = argparse.ArgumentParser(description='')
parser.add_argument('-m', '--metrics-port',      type=int, default=8004,                help='Port to expose prometheus metrics.')
parser.add_argument('-a', '--node-rest-address', type=str, default="http://nwaku:8645", help='Address of the waku node to send messages to.')
parser.add_argument('-p', '--pubsub-topic',      type=str, default='/waku/2/rs/1/0',    help='PubSub topic.')
parser.add_argument('-d', '--delay-seconds',     type=int, default=60,                  help='Delay in seconds between messages.')
parser.add_argument('-n', '--store-nodes',       type=str, required=True,               help='Comma separated list of store nodes to query.')
parser.add_argument('-t', '--health-threshold',  type=int, default=5,                   help='Consecutive successful store requests to consider a store node healthy.')
args = parser.parse_args()


# Logs message including current UTC time
def log_with_utc(message):
    utc_time = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{utc_time} UTC] {message}")


# Sends Sonda message. Returns True if successful, False otherwise
def send_sonda_msg(rest_address, pubsub_topic, content_topic, timestamp):
    message = "Hi, I'm Sonda"
    base64_message = base64.b64encode(message.encode('utf-8')).decode('ascii')
    body = {
        'payload': base64_message,
        'contentTopic': content_topic,
        'version': 1,
        'timestamp': timestamp
    }

    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')
    url = f'{rest_address}/relay/v1/messages/{encoded_pubsub_topic}'
    headers = {'content-type': 'application/json'}

    log_with_utc(f'Sending Sonda message via REST: {url} PubSubTopic: {pubsub_topic}, ContentTopic: {content_topic}, timestamp: {timestamp}')
    
    try:
        start_time = time.time()
        response = requests.post(url, json=body, headers=headers, timeout=10)
        elapsed_seconds = time.time() - start_time
        
        log_with_utc(f'Response from {rest_address}: status:{response.status_code} content:{response.text} [{elapsed_seconds:.4f} s.]')
        
        if response.status_code == 200:
            successful_sonda_msgs.inc()
            return True
        else:
            response.raise_for_status()
    except requests.RequestException as e:
        log_with_utc(f'Error sending request: {e}')
    
    failed_sonda_msgs.inc()
    return False


# Maps the cause of a store BAD_RESPONSE (300) onto the bounded error set.
# This is the only place where a cause string is inspected.
def classify_bad_response(cause):
    cause = cause.lower()
    if 'archive error' in cause or 'driver_error' in cause:
        return ERR_STORE_BACKEND_ERROR
    if 'cancel' in cause or 'timed out' in cause or 'timeout' in cause:
        return ERR_QUERY_TIMEOUT
    if 'closed' in cause or 'reset' in cause or 'eof' in cause:
        return ERR_PEER_UNREACHABLE
    return ERR_UNKNOWN


# Increments failed_store_queries with a bounded 'error' label, keeping the raw cause in
# the log only. blame_peer=False leaves 'node' empty for failures where sonda never got
# an answer about the store peer, so we don't blame a peer that was never contacted.
def record_store_failure(store_node, error, cause, blame_peer=True):
    log_with_utc(f'Failed store query node={store_node} error={error} cause={cause}')
    failed_store_queries.labels(node=store_node if blame_peer else '', error=error).inc()
    consecutive_successful_responses.labels(node=store_node).set(0)


# We return true if both our node and the queried Store node returned a 200
# If our message isn't found but we did get a store 200 response, this function still returns true
def check_store_response(json_response, store_node, timestamp):
  status_code = json_response.get('statusCode')
  status_desc = json_response.get('statusDesc') or ''

  # Check for the store node status code
  if status_code != 200:
    blame_peer = True
    if status_code == 300:
      error = classify_bad_response(status_desc)
    elif status_code in STORE_STATUS_ERRORS:
      error = STORE_STATUS_ERRORS[status_code]
    else:
      # A 400 means sonda built a bad query. That is a sonda bug, not the peer's fault.
      error = ERR_UNKNOWN
      blame_peer = False

    record_store_failure(store_node, error, f'{status_code} {status_desc}', blame_peer)
    return False

  messages = json_response.get('messages')
  # If there's no message in the response, increase counters and return
  if not messages:
    log_with_utc("No messages in store response")
    empty_store_responses.labels(node=store_node).inc()
    consecutive_successful_responses.labels(node=store_node).set(0)
    return True

  # Search for the Sonda message in the returned messages
  for message in messages:
    # If message field is missing in current message, continue
    if not message.get("message"):
      log_with_utc("Could not retrieve message")
      continue
    
    # If a message is found with the same timestamp as sonda message, increase counters and return
    if timestamp == message.get('message').get('timestamp'):
      log_with_utc(f'Found Sonda message in store response node={store_node}')
      successful_store_queries.labels(node=store_node).inc()
      consecutive_successful_responses.labels(node=store_node).inc()
      return True

  # If our message wasn't found in the returned messages, increase counter and return
  empty_store_responses.labels(node=store_node).inc()
  consecutive_successful_responses.labels(node=store_node).set(0)
  return True


def send_store_query(rest_address, store_node, encoded_pubsub_topic, encoded_content_topic, timestamp):
    url = f'{rest_address}/store/v3/messages'
    params = {
        'peerAddr': urllib.parse.quote(store_node, safe=''), 
        'pubsubTopic': encoded_pubsub_topic,
        'contentTopics': encoded_content_topic, 
        'includeData': 'true', 
        'startTime': timestamp
    }
    
    s_time = time.time()
    
    try:
        log_with_utc(f'Sending store request to {store_node}')
        response = requests.get(url, params=params)
    except requests.RequestException as e:
        # No HTTP response at all, so sonda learned nothing about the store peer.
        # Checked first: attributing this to a peer we never reached would be a lie.
        record_store_failure(store_node, ERR_LOCAL_NODE_UNREACHABLE, str(e), blame_peer=False)
        return False
    except Exception as e:
        # An exception inside sonda itself.
        record_store_failure(store_node, ERR_UNKNOWN, str(e), blame_peer=False)
        return False

    elapsed_seconds = time.time() - s_time
    log_with_utc(f'Response from {rest_address}: status:{response.status_code} [{elapsed_seconds:.4f} s.]')

    # Our node turns a store TOO_MANY_REQUESTS into an HTTP 429 instead of a status code.
    if response.status_code == 429:
        record_store_failure(store_node, ERR_STORE_BACKEND_ERROR, response.text)
        return False

    if response.status_code != 200:
        record_store_failure(store_node, ERR_UNKNOWN,
                             f'HTTP {response.status_code} {response.text}', blame_peer=False)
        return False

    # Parse REST response into JSON
    try:
        json_response = response.json()
    except ValueError as e:
        record_store_failure(store_node, ERR_UNKNOWN, str(e), blame_peer=False)
        return False

    # Analyze Store response. Return false if response is incorrect or has an error status
    if not check_store_response(json_response, store_node, timestamp):
        return False

    store_query_latency.labels(node=store_node).set(elapsed_seconds)
    return True


def send_store_queries(rest_address, store_nodes, pubsub_topic, content_topic, timestamp):
    log_with_utc(f'Sending store queries. nodes = {store_nodes} timestamp = {timestamp}')
    encoded_pubsub_topic = urllib.parse.quote(pubsub_topic, safe='')
    encoded_content_topic = urllib.parse.quote(content_topic, safe='')
    
    for node in store_nodes:
      send_store_query(rest_address, node, encoded_pubsub_topic, encoded_content_topic, timestamp)


def main():
  log_with_utc(f'Running Sonda with args={args}')

  store_nodes = []
  if args.store_nodes is not None:
      store_nodes = [s.strip() for s in args.store_nodes.split(",")]
  log_with_utc(f'Store nodes to query: {store_nodes}')

  # Start Prometheus HTTP server at port set by the CLI(default 8004)
  start_http_server(args.metrics_port)

  while True:
    timestamp = time.time_ns()
      
    # Send Sonda message
    res = send_sonda_msg(args.node_rest_address, args.pubsub_topic, SONDA_CONTENT_TOPIC, timestamp)

    log_with_utc(f'sleeping: {args.delay_seconds} seconds')
    time.sleep(args.delay_seconds)

    # Only send store query if message was successfully published
    if(res):
      send_store_queries(args.node_rest_address, store_nodes, args.pubsub_topic, SONDA_CONTENT_TOPIC, timestamp)
    
    # Update node health metrics
    for store_node in store_nodes:
      if consecutive_successful_responses.labels(node=store_node)._value.get() >= args.health_threshold:
        node_health.labels(node=store_node).set(1)
      else:
        node_health.labels(node=store_node).set(0)


main()
