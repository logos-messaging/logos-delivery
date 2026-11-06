#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>

#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "base64.h"
#include "../../library/liblogosdelivery_kernel.h"

// Shared synchronization variables
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
int callback_executed = 0;

void waitForCallback()
{
  pthread_mutex_lock(&mutex);
  while (!callback_executed)
  {
    pthread_cond_wait(&cond, &mutex);
  }
  callback_executed = 0;
  pthread_mutex_unlock(&mutex);
}

#define WAKU_CALL(call)                                                  \
  do                                                                     \
  {                                                                      \
    int ret = call;                                                      \
    if (ret != 0)                                                        \
    {                                                                    \
      printf("Failed the call to: %s. Returned code: %d\n", #call, ret); \
      exit(1);                                                           \
    }                                                                    \
    waitForCallback();                                                   \
  } while (0)

struct ConfigNode
{
  char host[128];
  int port;
  char key[128];
  int relay;
  char peers[2048];
  int store;
};

// Handed over by create_handler once the node exists.
LogosDeliveryCtx *ctx = NULL;

// For the case of C language we don't need to store a particular userData
void *userData = NULL;

// Arguments parsing. Uses POSIX getopt so the example builds on glibc and on
// macOS/BSD alike (argp is a GNU libc extension not available everywhere).
static void parse_args(int argc, char **argv, struct ConfigNode *cfgNode)
{
  int opt;
  while ((opt = getopt(argc, argv, "h:p:k:r:a:")) != -1)
  {
    switch (opt)
    {
    case 'h':
      snprintf(cfgNode->host, 128, "%s", optarg);
      break;
    case 'p':
      cfgNode->port = atoi(optarg);
      break;
    case 'k':
      snprintf(cfgNode->key, 128, "%s", optarg);
      break;
    case 'r':
      cfgNode->relay = atoi(optarg);
      break;
    case 'a':
      snprintf(cfgNode->peers, 2048, "%s", optarg);
      break;
    default:
      printf("Wrong parameters\n");
      exit(1);
    }
  }
}

void signal_cond()
{
  pthread_mutex_lock(&mutex);
  callback_executed = 1;
  pthread_cond_signal(&cond);
  pthread_mutex_unlock(&mutex);
}

// The reply shape of every logosdelivery_ctx_* call. `reply` is valid only
// during the call.
void reply_handler(int errCode, const char *const *reply, const char *errMsg, void *userData)
{
  if (errCode != RET_OK)
  {
    printf("Error: %s\n", errMsg != NULL ? errMsg : "(no message)");
    exit(1);
  }
  else if (reply != NULL)
  {
    printf("Receiving event: %s\n", *reply ? *reply : "");
  }

  signal_cond();
}

// LogosDeliveryCreateFn: on success the caller owns `newCtx`, and releases it
// with logosdelivery_ctx_destroy.
void create_handler(int errCode, LogosDeliveryCtx *newCtx, const char *errMsg, void *userData)
{
  if (errCode != RET_OK)
  {
    printf("Error: %s\n", errMsg != NULL ? errMsg : "(no message)");
    exit(1);
  }

  ctx = newCtx;
  signal_cond();
}

// FFICallback: the event-listener registry shape. `msg` is not NUL-terminated.
void on_event_received(int callerRet, const char *msg, size_t len, void *userData)
{
  if (callerRet == RET_ERR)
  {
    printf("Error: %.*s\n", (int)len, msg);
    exit(1);
  }
  else if (callerRet == RET_OK)
  {
    printf("Receiving event: %.*s\n", (int)len, msg);
  }
}

char *contentTopic = NULL;
void handle_content_topic(int errCode, const char *const *reply, const char *errMsg, void *userData)
{
  if (errCode != RET_OK)
  {
    printf("Error: %s\n", errMsg != NULL ? errMsg : "(no message)");
    exit(1);
  }
  // Copy the reply out: it is only valid inside this callback.
  free(contentTopic);
  contentTopic = strdup(*reply);
  signal_cond();
}

#define MAX_MSG_SIZE 65535

void publish_message(const char *msg)
{
  char jsonWakuMsg[MAX_MSG_SIZE];
  char *msgPayload = b64_encode(msg, strlen(msg));

  WAKU_CALL(logosdelivery_ctx_waku_content_topic(
      ctx, "appName", 1, "contentTopicName",
      "encoding", handle_content_topic, userData));
  snprintf(jsonWakuMsg,
           MAX_MSG_SIZE,
           "{\"payload\":\"%s\",\"contentTopic\":\"%s\"}",
           msgPayload, contentTopic);

  free(msgPayload);

  WAKU_CALL(logosdelivery_ctx_waku_relay_publish(
      ctx, "/waku/2/rs/16/32", jsonWakuMsg, 10000,
      reply_handler, userData));
}

// A reliable channel splits anything larger than one segment and reassembles
// it on the far side. `segmentationSegmentSizeBytes` defaults to 102400 and the
// wire header takes up to 128 of those, leaving 102272 bytes of payload per
// segment once rounded down to the 64-byte alignment Reed-Solomon needs.
// See README.md for how to confirm the split and the reassembly.
#define CHANNEL_SEGMENT_PAYLOAD 102272
#define CHANNEL_DATA_SEGMENTS 4

static const char *kChannelId = "c-example-large";
// A real node validates this: /<application>/<version>/<topic-name>/<encoding>.
static const char *kChannelTopic = "/c-example/1/large-message/proto";

// Both ends need the channel: creating it subscribes to the content topic, so
// a node that never calls this receives nothing. Done at startup rather than on
// the first send, so an instance can be receive-only.
void ensure_channel(const char *senderId)
{
  static int channelReady = 0;
  if (channelReady)
  {
    return;
  }
  // Unencrypted: no cipher functions and no cipher user data.
  WAKU_CALL(logosdelivery_ctx_channel_create(
      ctx, kChannelId, kChannelTopic,
      senderId, 0, 0, 0, reply_handler, userData));
  channelReady = 1;
}

void send_large_channel_message()
{

  // One byte past three whole segments, so the payload needs a fourth.
  const size_t payloadLen = (CHANNEL_DATA_SEGMENTS - 1) * CHANNEL_SEGMENT_PAYLOAD + 1;
  unsigned char *payload = malloc(payloadLen);
  if (payload == NULL)
  {
    printf("Could not allocate the payload\n");
    return;
  }
  // A non-repeating pattern, so a mis-ordered reassembly cannot look correct.
  // Seeded per send: an identical payload yields identical SDS message ids,
  // which a peer that already saw them discards as duplicates.
  const unsigned char seed = (unsigned char)time(NULL);
  for (size_t i = 0; i < payloadLen; i++)
  {
    payload[i] = (unsigned char)(i * 31 + (i / 251) * 7 + seed);
  }

  char *payloadB64 = b64_encode(payload, payloadLen);
  free(payload);
  if (payloadB64 == NULL)
  {
    printf("Could not base64-encode the payload\n");
    return;
  }

  const size_t jsonLen = strlen(payloadB64) + 64;
  char *messageJson = malloc(jsonLen);
  if (messageJson == NULL)
  {
    free(payloadB64);
    printf("Could not allocate the message\n");
    return;
  }
  snprintf(messageJson, jsonLen, "{\"payload\":\"%s\",\"ephemeral\":false}", payloadB64);
  free(payloadB64);

  printf("Sending %zu bytes over channel '%s': expect %d segments on the wire,\n"
         "and a single onChannelMessageReceived on any peer that reassembles it.\n",
         payloadLen, kChannelId, CHANNEL_DATA_SEGMENTS);

  WAKU_CALL(logosdelivery_ctx_channel_send(ctx, kChannelId,
                                           messageJson,
                                           reply_handler, userData));
  free(messageJson);
}

void show_help_and_exit()
{
  printf("Wrong parameters\n");
  exit(1);
}

void print_default_pubsub_topic(int errCode, const char *const *reply, const char *errMsg, void *userData)
{
  printf("Default pubsub topic: %s\n", reply && *reply ? *reply : "");
  signal_cond();
}

void print_waku_version(int errCode, const char *const *reply, const char *errMsg, void *userData)
{
  printf("Git Version: %s\n", reply && *reply ? *reply : "");
  signal_cond();
}

// Beginning of UI program logic

enum PROGRAM_STATE
{
  MAIN_MENU,
  SUBSCRIBE_TOPIC_MENU,
  CONNECT_TO_OTHER_NODE_MENU,
  PUBLISH_MESSAGE_MENU,
  SEND_LARGE_CHANNEL_MESSAGE_MENU
};

enum PROGRAM_STATE current_state = MAIN_MENU;

void show_main_menu()
{
  printf("\nPlease, select an option:\n");
  printf("\t1.) Subscribe to topic\n");
  printf("\t2.) Connect to other node\n");
  printf("\t3.) Publish a message\n");
  printf("\t4.) Send a large message over a reliable channel (segmented)\n");
}

void handle_user_input()
{
  char cmd[1024];
  memset(cmd, 0, 1024);
  int numRead = read(0, cmd, 1024);
  if (numRead <= 0)
  {
    return;
  }

  switch (atoi(cmd))
  {
  case SUBSCRIBE_TOPIC_MENU:
  {
    printf("Indicate the Pubsubtopic to subscribe:\n");
    char pubsubTopic[128];
    scanf("%127s", pubsubTopic);

    WAKU_CALL(logosdelivery_ctx_waku_relay_subscribe(ctx, pubsubTopic,
                                                     reply_handler, userData));
    printf("The subscription went well\n");

    show_main_menu();
  }
  break;

  case CONNECT_TO_OTHER_NODE_MENU:
  {
    printf("Connecting to a node. Please indicate the peer Multiaddress:\n");
    printf("e.g.: /ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\n");
    char peerAddr[512];
    scanf("%511s", peerAddr);

    WAKU_CALL(logosdelivery_ctx_waku_connect(ctx, peerAddr, 10000,
                                             reply_handler, userData));
    printf("Connected\n");

    show_main_menu();
  }
  break;

  case PUBLISH_MESSAGE_MENU:
  {
    printf("Type the message to publish:\n");
    char msg[1024];
    scanf("%1023s", msg);

    publish_message(msg);

    show_main_menu();
  }
  break;

  case SEND_LARGE_CHANNEL_MESSAGE_MENU:
  {
    send_large_channel_message();
    show_main_menu();
  }
  break;

  case MAIN_MENU:
    break;
  }
}

// End of UI program logic

int main(int argc, char **argv)
{
  struct ConfigNode cfgNode;
  // default values
  snprintf(cfgNode.host, 128, "0.0.0.0");
  cfgNode.port = 60000;
  cfgNode.relay = 1;

  cfgNode.store = 0;

  parse_args(argc, argv, &cfgNode);

  char jsonConfig[5000];
  snprintf(jsonConfig, 5000, "{ \
                                    \"mode\": \"Core\", \
                                    \"preset\": \"status.prod\", \
                                    \"messagingOverrides\": { \
                                        \"listen-address\": \"%s\",    \
                                        \"tcp-port\": %d,        \
                                        \"store\": %s,       \
                                        \"log-level\": \"DEBUG\", \
                                        \"discv5-udp-port\": %d \
                                    } \
                                }",
           cfgNode.host,
           cfgNode.port,
           cfgNode.store ? "true" : "false",
           // Derived from the TCP port, so a second local instance does not
           // fail to start with "Address already in use".
           cfgNode.port + 1);

  WAKU_CALL(logosdelivery_ctx_create(jsonConfig, create_handler, userData));

  WAKU_CALL(logosdelivery_ctx_waku_default_pubsub_topic(ctx, print_default_pubsub_topic, userData));
  WAKU_CALL(logosdelivery_ctx_waku_version(ctx, print_waku_version, userData));

  printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
  printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES" : "NO");

  static const char *kEventNames[] = {
      "onMessageSent",            "onMessageError",
      "onMessagePropagated",      "onMessageReceived",
      "onConnectionStatusChange", "onTopicHealthChange",
      "onConnectionChange",       "onReceivedMessage",
      "onChannelMessageReceived", "onChannelMessageSent",
      "onChannelMessageError",     "onChannelMessageLost"};
  for (size_t i = 0; i < sizeof(kEventNames) / sizeof(kEventNames[0]); i++)
    logosdelivery_add_event_listener(ctx->ptr, kEventNames[i], on_event_received, userData);

  WAKU_CALL(logosdelivery_ctx_start_node(ctx, reply_handler, userData));

  WAKU_CALL(logosdelivery_ctx_waku_listen_addresses(ctx, reply_handler, userData));

  WAKU_CALL(logosdelivery_ctx_waku_relay_subscribe(ctx, "/waku/2/rs/16/32",
                                                   reply_handler, userData));

  const char *bootnodes =
          "[\"enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw\",\"enr:-QEkuEB3WHNS-xA3RDpfu9A2Qycr3bN3u7VoArMEiDIFZJ66F1EB3d4wxZN1hcdcOX-RfuXB-MQauhJGQbpz3qUofOtLAYJpZIJ2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQPK35Nnz0cWUtSAhBp7zvHEhyU_AqeQUlqzLiLxfP2L4oN0Y3CCdl-DdWRwgiMohXdha3UyDw\"]";
  WAKU_CALL(logosdelivery_ctx_waku_discv5_update_bootnodes(ctx, bootnodes,
                                                           reply_handler, userData));

  WAKU_CALL(logosdelivery_ctx_waku_get_peerids_from_peerstore(ctx, reply_handler, userData));

  // Distinct per instance: SDS drops messages whose sender id matches its own
  // participant id, so two local nodes sharing one id never see each other.
  char senderId[64];
  snprintf(senderId, sizeof(senderId), "c-example-%d", cfgNode.port);
  ensure_channel(senderId);

  show_main_menu();
  while (1)
  {
    handle_user_input();

    // Uncomment the following if need to test the metrics retrieval
    // WAKU_CALL(logosdelivery_ctx_waku_get_metrics(ctx, reply_handler, userData));
  }

  pthread_mutex_destroy(&mutex);
  pthread_cond_destroy(&cond);
}
