#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <argp.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <vector>
#include <iostream>

#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>

#include "base64.h"
#include "../../library/libwaku.h"

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

void signal_cond()
{
    pthread_mutex_lock(&mutex);
    callback_executed = 1;
    pthread_cond_signal(&cond);
    pthread_mutex_unlock(&mutex);
}

#define WAKU_CALL(call)                                                                \
    do                                                                                 \
    {                                                                                  \
        int ret = call;                                                                \
        if (ret != 0)                                                                  \
        {                                                                              \
            std::cout << "Failed the call to: " << #call << ". Code: " << ret << "\n"; \
        }                                                                              \
        waitForCallback();                                                             \
    } while (0)

struct ConfigNode
{
    char host[128];
    int port;
    char key[128];
    int relay;
    char peers[2048];
};

// Arguments parsing
static char doc[] = "\nC example that shows how to use the waku library.";
static char args_doc[] = "";

static struct argp_option options[] = {
    {"host", 'h', "HOST", 0, "IP to listen for for LibP2P traffic. (default: \"0.0.0.0\")"},
    {"port", 'p', "PORT", 0, "TCP listening port. (default: \"60000\")"},
    {"key", 'k', "KEY", 0, "P2P node private key as 64 char hex string."},
    {"relay", 'r', "RELAY", 0, "Enable relay protocol: 1 or 0. (default: 1)"},
    {"peers", 'a', "PEERS", 0, "Comma-separated list of peer-multiaddress to connect\
 to. (default: \"\") e.g. \"/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\""},
    {0}};

static error_t parse_opt(int key, char *arg, struct argp_state *state)
{

    struct ConfigNode *cfgNode = (ConfigNode *)state->input;
    switch (key)
    {
    case 'h':
        snprintf(cfgNode->host, 128, "%s", arg);
        break;
    case 'p':
        cfgNode->port = atoi(arg);
        break;
    case 'k':
        snprintf(cfgNode->key, 128, "%s", arg);
        break;
    case 'r':
        cfgNode->relay = atoi(arg);
        break;
    case 'a':
        snprintf(cfgNode->peers, 2048, "%s", arg);
        break;
    case ARGP_KEY_ARG:
        if (state->arg_num >= 1) /* Too many arguments. */
            argp_usage(state);
        break;
    case ARGP_KEY_END:
        break;
    default:
        return ARGP_ERR_UNKNOWN;
    }

    return 0;
}

void event_handler(const char *msg, size_t len)
{
    printf("Receiving event: %s\n", msg);
}

void handle_error(const char *msg, size_t len)
{
    printf("handle_error: %s\n", msg);
    exit(1);
}

template <class F>
auto cify(F &&f)
{
    static F fn = std::forward<F>(f);
    return [](int callerRet, const char *msg, size_t len, void *userData)
    {
        signal_cond();
        return fn(msg, len);
    };
}

static struct argp argp = {options, parse_opt, args_doc, doc, 0, 0, 0};

// Beginning of UI program logic

enum PROGRAM_STATE
{
    MAIN_MENU,
    SUBSCRIBE_TOPIC_MENU,
    CONNECT_TO_OTHER_NODE_MENU,
    PUBLISH_MESSAGE_MENU
};

enum PROGRAM_STATE current_state = MAIN_MENU;

void show_main_menu()
{
    printf("\nPlease, select an option:\n");
    printf("\t1.) Subscribe to topic\n");
    printf("\t2.) Connect to other node\n");
    printf("\t3.) Publish a message\n");
}

void handle_user_input(void *ctx)
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

        WAKU_CALL(waku_relay_subscribe(ctx,
                                       cify([&](const char *msg, size_t len)
                                            { event_handler(msg, len); }),
                                       nullptr,
                                       pubsubTopic));
        printf("The subscription went well\n");

        show_main_menu();
    }
    break;

    case CONNECT_TO_OTHER_NODE_MENU:
        printf("Connecting to a node. Please indicate the peer Multiaddress:\n");
        printf("e.g.: /ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\n");
        char peerAddr[512];
        scanf("%511s", peerAddr);
        WAKU_CALL(waku_connect(ctx,
                               cify([&](const char *msg, size_t len)
                                    { event_handler(msg, len); }),
                               nullptr,
                               peerAddr,
                               10000 /* timeoutMs */));
        show_main_menu();
        break;

    case PUBLISH_MESSAGE_MENU:
    {
        printf("Type the message to publish:\n");
        char msg[1024];
        scanf("%1023s", msg);

        char jsonWakuMsg[2048];
        std::vector<char> msgPayload;
        b64_encode(msg, strlen(msg), msgPayload);

        std::string contentTopic;
        waku_content_topic(ctx,
                           cify([&contentTopic](const char *msg, size_t len)
                                { contentTopic = msg; }),
                           nullptr,
                           "appName",
                           1,
                           "contentTopicName",
                           "encoding");

        snprintf(jsonWakuMsg,
                 2048,
                 "{\"payload\":\"%s\",\"contentTopic\":\"%s\"}",
                 msgPayload.data(), contentTopic.c_str());

        WAKU_CALL(waku_relay_publish(ctx,
                                     cify([&](const char *msg, size_t len)
                                          { event_handler(msg, len); }),
                                     nullptr,
                                     "/waku/2/rs/16/32",
                                     jsonWakuMsg,
                                     10000 /*timeout ms*/));

        show_main_menu();
    }
    break;

    case MAIN_MENU:
        break;
    }
}

// End of UI program logic

void show_help_and_exit()
{
    printf("Wrong parameters\n");
    exit(1);
}

int main(int argc, char **argv)
{
    struct ConfigNode cfgNode;
    // default values
    snprintf(cfgNode.host, 128, "0.0.0.0");
    snprintf(cfgNode.key, 128,
             "364d111d729a6eb6d2e6113e163f017b5ef03a6f94c9b5b7bb1bb36fa5cb07a9");
    cfgNode.port = 60000;
    cfgNode.relay = 1;

    if (argp_parse(&argp, argc, argv, 0, 0, &cfgNode) == ARGP_ERR_UNKNOWN)
    {
        show_help_and_exit();
    }

    char jsonConfig[2048];
    snprintf(jsonConfig, 2048, "{ \
                                    \"host\": \"%s\",   \
                                    \"port\": %d,       \
                                    \"relay\": true,      \
                                    \"clusterId\": 16, \
                                    \"shards\": [ 1, 32, 64, 128, 256 ], \
                                    \"logLevel\": \"FATAL\", \
                                    \"discv5Discovery\": true, \
                                    \"discv5BootstrapNodes\": \
                                        [\"enr:-QESuEB4Dchgjn7gfAvwB00CxTA-nGiyk-aALI-H4dYSZD3rUk7bZHmP8d2U6xDiQ2vZffpo45Jp7zKNdnwDUx6g4o6XAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOvD3S3jUNICsrOILlmhENiWAMmMVlAl6-Q8wRB7hidY4N0Y3CCdl-DdWRwgiMohXdha3UyDw\", \"enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw\"], \
                                    \"discv5UdpPort\": 9999, \
                                    \"dnsDiscoveryUrl\": \"enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.prod.status.nodes.status.im\", \
                                    \"dnsDiscoveryNameServers\": [\"8.8.8.8\", \"1.0.0.1\"] \
                                }",
             cfgNode.host,
             cfgNode.port);

    void *ctx =
        waku_new(jsonConfig,
                 cify([](const char *msg, size_t len)
                      { std::cout << "waku_new feedback: " << msg << std::endl; }),
                 nullptr);
    waitForCallback();

    // example on how to retrieve a value from the `libwaku` callback.
    std::string defaultPubsubTopic;
    WAKU_CALL(
        waku_default_pubsub_topic(
            ctx,
            cify([&defaultPubsubTopic](const char *msg, size_t len)
                 { defaultPubsubTopic = msg; }),
            nullptr));

    std::cout << "Default pubsub topic: " << defaultPubsubTopic << std::endl;

    WAKU_CALL(waku_version(ctx,
                           cify([&](const char *msg, size_t len)
                                { std::cout << "Git Version: " << msg << std::endl; }),
                           nullptr));

    printf("Bind addr: %s:%u\n", cfgNode.host, cfgNode.port);
    printf("Waku Relay enabled: %s\n", cfgNode.relay == 1 ? "YES" : "NO");

    std::string pubsubTopic;
    WAKU_CALL(waku_pubsub_topic(ctx,
                                cify([&](const char *msg, size_t len)
                                     { pubsubTopic = msg; }),
                                nullptr,
                                "example"));

    std::cout << "Custom pubsub topic: " << pubsubTopic << std::endl;

    set_event_callback(ctx,
                       cify([&](const char *msg, size_t len)
                            { event_handler(msg, len); }),
                       nullptr);

    WAKU_CALL(waku_start(ctx,
                         cify([&](const char *msg, size_t len)
                              { event_handler(msg, len); }),
                         nullptr));

    WAKU_CALL(waku_relay_subscribe(ctx,
                                   cify([&](const char *msg, size_t len)
                                        { event_handler(msg, len); }),
                                   nullptr,
                                   defaultPubsubTopic.c_str()));

    show_main_menu();
    while (1)
    {
        handle_user_input(ctx);
    }
}
