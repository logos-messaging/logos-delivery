import ctypes
import argparse
import sys

if sys.platform == "darwin":
    _lib_ext = "dylib"
elif sys.platform == "win32":
    _lib_ext = "dll"
else:
    _lib_ext = "so"

_lib_path = f"build/liblogosdelivery.{_lib_ext}"

libwaku = object
try:
    # This python script should be run from the root repo folder
    libwaku = ctypes.CDLL(_lib_path)
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

def handle_event(ret, msg, msg_len, user_data):
    print("Event received: %s" % msg)

def call_waku(func):
    ret = func()
    if (ret != 0):
        print("Error in %s. Error code: %d" % (locals().keys(), ret))
        exit(1)

# Parse params
parser = argparse.ArgumentParser(description='libwaku integration in Python.')
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
                \"messagingOverrides\": { \
                    \"listen-address\": \"%s\", \
                    \"tcp-port\": %d,           \
                    \"nodekey\": \"%s\",        \
                    \"log-level\": \"DEBUG\"    \
                } \
            }" % (args.host,
                  int(args.port),
                  args.key)

# ctypes binds by name, so nothing here is checked against
# library/generated/logosdelivery.h: a stale signature imports and runs, and
# only misbehaves once it is called. Keep these in step with the header by hand.

# LogosDeliveryScalarRawFn, and the FFICallback event-listener shape.
callback_type = ctypes.CFUNCTYPE(
    None, ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p)

# LogosDelivery*ReplyFn, and CreateRawFn: no length, and the failure text
# arrives in its own argument.
reply_callback_type = ctypes.CFUNCTYPE(
    None, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p)


class CreateNodeCtorReq(ctypes.Structure):
    _fields_ = [("configJson", ctypes.c_char_p)]


class RelaySubscribeReq(ctypes.Structure):
    _fields_ = [("pubSubTopic", ctypes.c_char_p)]


class ConnectReq(ctypes.Structure):
    _fields_ = [("peerMultiAddr", ctypes.c_char_p), ("timeoutMs", ctypes.c_uint32)]


# Node creation
libwaku.logosdelivery_create_node.restype = ctypes.c_void_p
libwaku.logosdelivery_create_node.argtypes = [ctypes.POINTER(CreateNodeCtorReq),
                             reply_callback_type,
                             ctypes.c_void_p]

create_req = CreateNodeCtorReq(configJson=bytes(json_config, 'utf-8'))
on_create_cb = reply_callback_type(
    #onErrCb
    lambda ret, reply, err, user_data:
      print("Error calling logosdelivery_create_node: %s",
            (err or b"").decode('utf-8')))
ctx = libwaku.logosdelivery_create_node(ctypes.byref(create_req),
                       on_create_cb,
                       ctypes.c_void_p(0))

# Retrieve the current version of the library
libwaku.waku_version.argtypes = [ctypes.c_void_p,
                                 callback_type,
                                 ctypes.c_void_p]
on_version_cb = callback_type(lambda ret, msg, len, user_data:
                              print("Git Version: %s" % msg.decode('utf-8')))
libwaku.waku_version(ctx, on_version_cb, ctypes.c_void_p(0))

# Retrieve the default pubsub topic
default_pubsub_topic = ""
libwaku.waku_default_pubsub_topic.argtypes = [ctypes.c_void_p,
                                 callback_type,
                                 ctypes.c_void_p]
on_default_topic_cb = callback_type(
    lambda ret, msg, len, user_data: (
        globals().update(default_pubsub_topic = msg.decode('utf-8')),
        print("Default pubsub topic: %s" % msg.decode('utf-8'))))
libwaku.waku_default_pubsub_topic(ctx, on_default_topic_cb, ctypes.c_void_p(0))

print("Bind addr: {}:{}".format(args.host, args.port))
print("Waku Relay enabled: {}".format(args.relay))

# Set the event callback
callback = callback_type(handle_event) # This line is important so that the callback is not gc'ed

libwaku.logosdelivery_add_event_listener.argtypes = [ctypes.c_void_p,
                                                     ctypes.c_char_p,
                                                     callback_type,
                                                     ctypes.c_void_p]
libwaku.logosdelivery_add_event_listener.restype = ctypes.c_uint64
for event_name in [b"onMessageSent", b"onMessageError", b"onMessagePropagated",
                   b"onMessageReceived", b"onConnectionStatusChange",
                   b"onTopicHealthChange", b"onConnectionChange", b"onReceivedMessage",
                   b"onChannelMessageReceived", b"onChannelMessageSent",
                   b"onChannelMessageError"]:
    libwaku.logosdelivery_add_event_listener(ctx, event_name, callback, ctypes.c_void_p(0))

# Start the node
libwaku.logosdelivery_start_node.argtypes = [ctypes.c_void_p,
                               callback_type,
                               ctypes.c_void_p]
on_start_cb = callback_type(lambda ret, msg, len, user_data:
                            print("Error in logosdelivery_start_node: %s" %
                                  msg.decode('utf-8')))
libwaku.logosdelivery_start_node(ctx, on_start_cb, ctypes.c_void_p(0))

# Subscribe to the default pubsub topic
libwaku.waku_relay_subscribe.argtypes = [ctypes.c_void_p,
                                         reply_callback_type,
                                         ctypes.c_void_p,
                                         ctypes.POINTER(RelaySubscribeReq)]
subscribe_req = RelaySubscribeReq(pubSubTopic=default_pubsub_topic.encode('utf-8'))
on_subscribe_cb = reply_callback_type(
    #onErrCb
    lambda ret, reply, err, user_data:
        print("Error calling waku_relay_subscribe: %s" % (err or b"").decode('utf-8')))
libwaku.waku_relay_subscribe(ctx, on_subscribe_cb, ctypes.c_void_p(0),
                             ctypes.byref(subscribe_req))

libwaku.waku_connect.argtypes = [ctypes.c_void_p,
                                 reply_callback_type,
                                 ctypes.c_void_p,
                                 ctypes.POINTER(ConnectReq)]
connect_req = ConnectReq(peerMultiAddr=args.peer.encode('utf-8'), timeoutMs=10000)
on_connect_cb = reply_callback_type(
    # onErrCb
    lambda ret, reply, err, user_data:
      print("Error calling waku_connect: %s" % (err or b"").decode('utf-8')))
libwaku.waku_connect(ctx, on_connect_cb, ctypes.c_void_p(0),
                     ctypes.byref(connect_req))

# app = Flask(__name__)
# @app.route("/")
# def hello_world():
#     return "Hello, World!"

# Simply avoid the app to
a = input()

