from flask import Flask
import ctypes
import argparse

libwaku = object
try:
    # This python script should be run from the root repo folder
    libwaku = ctypes.CDLL("build/libwaku.so")
except Exception as e:
    print("Exception: ", e)
    print("""
The 'libwaku.so' library can be created with the next command from
the repo's root folder: `make libwaku`.

And it should build the library in 'build/libwaku.so'.

Therefore, make sure the LD_LIBRARY_PATH env var points at the location that
contains the 'libwaku.so' library.
""")
    exit(-1)

def handle_event(ret, msg, user_data):
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

# The next 'json_config' is the item passed to the 'waku_new'.
json_config = "{ \
                \"host\": \"%s\",   \
                \"port\": %d,       \
                \"key\": \"%s\",    \
                \"relay\": %s      ,\
                \"logLevel\": \"DEBUG\" \
            }" % (args.host,
                  int(args.port),
                  args.key,
                  "true" if args.relay else "false")

callback_type = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t)

# Node creation
libwaku.waku_new.restype = ctypes.c_void_p
libwaku.waku_new.argtypes = [ctypes.c_char_p,
                             callback_type,
                             ctypes.c_void_p]

ctx = libwaku.waku_new(bytes(json_config, 'utf-8'),
                       callback_type(
                           #onErrCb
                           lambda ret, msg, len:
                             print("Error calling waku_new: %s",
                                   msg.decode('utf-8'))
                           ),
                           ctypes.c_void_p(0))

# Retrieve the current version of the library
libwaku.waku_version.argtypes = [ctypes.c_void_p,
                                 callback_type,
                                 ctypes.c_void_p]
libwaku.waku_version(ctx,
                     callback_type(lambda ret, msg, len:
                                  print("Git Version: %s" %
                                        msg.decode('utf-8'))),
                     ctypes.c_void_p(0))

# Retrieve the default pubsub topic
default_pubsub_topic = ""
libwaku.waku_default_pubsub_topic.argtypes = [ctypes.c_void_p,
                                 callback_type,
                                 ctypes.c_void_p]
libwaku.waku_default_pubsub_topic(ctx,
                                  callback_type(
                                        lambda ret, msg, len: (
                                            globals().update(default_pubsub_topic = msg.decode('utf-8')),
                                            print("Default pubsub topic: %s" % msg.decode('utf-8')))
                                  ),
                                  ctypes.c_void_p(0))

print("Bind addr: {}:{}".format(args.host, args.port))
print("Waku Relay enabled: {}".format(args.relay))

# Set the event callback
callback = callback_type(handle_event) # This line is important so that the callback is not gc'ed

libwaku.set_event_callback.argtypes = [callback_type, ctypes.c_void_p]
libwaku.set_event_callback(callback, ctypes.c_void_p(0))

# Start the node
libwaku.waku_start.argtypes = [ctypes.c_void_p,
                               callback_type,
                               ctypes.c_void_p]
libwaku.waku_start(ctx,
                   callback_type(lambda ret, msg, len:
                                  print("Error in waku_start: %s" %
                                        msg.decode('utf-8'))),
                   ctypes.c_void_p(0))

# Subscribe to the default pubsub topic
libwaku.waku_relay_subscribe.argtypes = [ctypes.c_void_p,
                                         callback_type,
                                         ctypes.c_void_p,
                                         ctypes.c_char_p]
libwaku.waku_relay_subscribe(ctx,
                             callback_type(
                                    #onErrCb
                                    lambda ret, msg, len:
                                        print("Error calling waku_relay_subscribe: %s" %
                                                msg.decode('utf-8'))
                             ),
                             ctypes.c_void_p(0),
                             default_pubsub_topic.encode('utf-8'))

libwaku.waku_connect.argtypes = [ctypes.c_void_p,
                                 callback_type,
                                 ctypes.c_void_p,
                                 ctypes.c_char_p,
                                 ctypes.c_int]
libwaku.waku_connect(ctx,
                     # onErrCb
                     callback_type(
                         lambda ret, msg, len:
                           print("Error calling waku_connect: %s" % msg.decode('utf-8'))),
                     ctypes.c_void_p(0),
                     args.peer.encode('utf-8'),
                     10000)

# app = Flask(__name__)
# @app.route("/")
# def hello_world():
#     return "Hello, World!"

# Simply avoid the app to
a = input()

