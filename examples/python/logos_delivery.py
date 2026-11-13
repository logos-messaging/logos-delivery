import argparse
import ctypes
import sys
import threading

import cbor2

if sys.platform == "darwin":
    _lib_ext = "dylib"
elif sys.platform == "win32":
    _lib_ext = "dll"
else:
    _lib_ext = "so"

_lib_path = f"build/liblogosdelivery.{_lib_ext}"

try:
    # This python script should be run from the root repo folder
    liblogosdelivery = ctypes.CDLL(_lib_path)
except OSError as e:
    print(f"Exception: {e}")
    print(f"""
The '{_lib_path}' library can be created with the next command from
the repo's root folder: `make liblogosdelivery`.

And it should build the library in '{_lib_path}'.

Therefore, make sure the library path env var points at the location that
contains the '{_lib_path}' library.
""")
    exit(1)

# Parse params
parser = argparse.ArgumentParser(description='liblogosdelivery integration in Python.')
parser.add_argument('-d', '--host', dest='host', default='0.0.0.0',
                    help='Address this node will listen to. [=0.0.0.0]')
parser.add_argument('-p', '--port', dest='port', default=60000, required=True,
                    help='Port this node will listen to. [=60000]')
parser.add_argument('-k', '--key', dest='key', default="", required=True,
                    help="""P2P node private key as 64 char hex string.
e.g.: 364d111d729a6eb6d2e6113e163f017b5ef03a6f94c9b5b7bb1bb36fa5cb07a9""")
parser.add_argument('-r', '--relay', dest='relay', default="true",
                    help="Enable relay protocol: true|false [=true]")
parser.add_argument('--peer', dest='peer', default="",
                    help="Multiqualified libp2p address")

args = parser.parse_args()

# The next 'json_config' is the item passed to the 'logosdelivery_create_node'.
json_config = "{ \
                \"mode\": \"Core\", \
                \"listen-address\": \"%s\", \
                \"tcp-port\": %d,           \
                \"nodekey\": \"%s\",        \
                \"log-level\": \"DEBUG\"    \
            }" % (args.host,
                  int(args.port),
                  args.key)

# ctypes binds by name, so nothing here is checked against
# build/generated/logosdelivery.h: a stale signature imports and runs, and
# only misbehaves once it is called. Keep these in step with the header by hand.
#
# The raw entry points take their request as a CBOR map and answer with a
# CBOR value on success, or with the plain error text on failure.

RET_OK = 0
RET_STALE_WARN = 3

# FFICallback: `msg` is a byte run of `len` bytes.
callback_type = ctypes.CFUNCTYPE(
    None, ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p)

_req_args = [ctypes.c_void_p, callback_type, ctypes.c_void_p,
             ctypes.c_char_p, ctypes.c_size_t]

liblogosdelivery.logosdelivery_create_node.restype = ctypes.c_void_p
liblogosdelivery.logosdelivery_create_node.argtypes = [
    ctypes.c_char_p, ctypes.c_size_t, callback_type, ctypes.c_void_p]
for name in ["logosdelivery_start_node", "waku_version",
             "waku_default_pubsub_topic", "waku_relay_subscribe", "waku_connect"]:
    getattr(liblogosdelivery, name).argtypes = _req_args
    getattr(liblogosdelivery, name).restype = ctypes.c_int
liblogosdelivery.logosdelivery_add_event_listener.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, callback_type, ctypes.c_void_p]
liblogosdelivery.logosdelivery_add_event_listener.restype = ctypes.c_uint64


def call(what, invoke, req=None):
    """Runs one raw call and waits for its terminal reply: the library answers
    on its own thread."""
    done = threading.Event()
    reply = {}

    def on_reply(ret, msg, msg_len, user_data):
        if ret == RET_STALE_WARN:
            return
        data = ctypes.string_at(msg, msg_len) if msg else b""
        if ret == RET_OK:
            reply["value"] = cbor2.loads(data)
        else:
            reply["error"] = data.decode("utf-8", "replace")
        done.set()

    cb = callback_type(on_reply)  # kept alive until the reply arrives
    req_cbor = cbor2.dumps(req or {})
    invoke(cb, req_cbor, len(req_cbor))
    if not done.wait(30):
        sys.exit(f"no reply from {what}")
    if "error" in reply:
        sys.exit(f"{what} failed: {reply['error']}")
    return reply["value"]


# Node creation: the reply carries the context address as decimal text.
ctx = int(call("logosdelivery_create_node",
               lambda cb, req, n: liblogosdelivery.logosdelivery_create_node(
                   req, n, cb, None),
               {"configJson": json_config}))


def ctx_call(name, req=None):
    fn = getattr(liblogosdelivery, name)
    return call(name, lambda cb, r, n: fn(ctx, cb, None, r, n), req)


print("Git Version: %s" % ctx_call("waku_version"))
default_pubsub_topic = ctx_call("waku_default_pubsub_topic")
print("Default pubsub topic: %s" % default_pubsub_topic)

print("Bind addr: {}:{}".format(args.host, args.port))
print("Relay enabled: {}".format(args.relay))


def handle_event(ret, msg, msg_len, user_data):
    print("Event received: %s" % cbor2.loads(ctypes.string_at(msg, msg_len)))


event_callback = callback_type(handle_event)  # kept alive for the node's life
for event_name in [b"onMessageSent", b"onMessageError", b"onMessagePropagated",
                   b"onMessageReceived", b"onConnectionStatusChange",
                   b"onTopicHealthChange", b"onConnectionChange", b"onReceivedMessage",
                   b"onChannelMessageReceived", b"onChannelMessageSent",
                   b"onChannelMessageError"]:
    liblogosdelivery.logosdelivery_add_event_listener(ctx, event_name, event_callback, None)

ctx_call("logosdelivery_start_node")
print("Node started")

ctx_call("waku_relay_subscribe", {"pubSubTopic": default_pubsub_topic})
print("Subscribed to: %s" % default_pubsub_topic)

if args.peer:
    ctx_call("waku_connect", {"peerMultiAddr": args.peer, "timeoutMs": 10000})
    print("Connected to: %s" % args.peer)

# Keep the node running until Enter is pressed
input()
