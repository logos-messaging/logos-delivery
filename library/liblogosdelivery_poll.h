/* liblogosdelivery, nim-ffi poll-mode C ABI (nim-ffi dual/6-reverse,
 * -d:ffiPollMode). Hand-written: nim-ffi's header backend still describes the
 * callback model. Every export has one shape, so this file is the message
 * layout, the status codes, and the names.
 *
 * A method call is
 *     int logosdelivery_<m>(void* ctx, const uint8_t* req, size_t len, uint64_t* id_out);
 * `req` is a CBOR map keyed by the Nim proc's parameter names (the field names
 * of the old *Req structs). RET_OK promises exactly one REPLY message carrying
 * `*id_out`; any other return means no reply will come. Everything the library
 * has to say -- replies, events, its questions for the host (REVERSE_CALL) --
 * comes out of logosdelivery_poll(), and logosdelivery_poll_fd() is readable
 * while a message waits. Both may be called from any host thread; so may
 * logosdelivery_reverse_reply(). */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    RET_OK = 0, RET_ERR = 1, RET_MISSING_CALLBACK = 2, RET_STALE_WARN = 3, RET_TIMEOUT = 4,
    RET_CLOSED = 5, RET_INVALID_CTX = 6, RET_BUSY = 7, RET_QUEUE_FULL = 8, RET_TOO_LARGE = 9
};
enum {
    NIMFFI_MSG_REPLY = 1,          /* id: the request; OK: payload is its CBOR, ERR: UTF-8 text */
    NIMFFI_MSG_EVENT = 2,          /* name_id names it; payload is its CBOR */
    NIMFFI_MSG_STALE_WARN = 3,     /* progress tick on a long call; not terminal */
    NIMFFI_MSG_REVERSE_CALL = 4,   /* id: the call; name_id names it; payload: CBOR args */
    NIMFFI_MSG_NOT_RESPONDING = 5,
    NIMFFI_MSG_RESPONDING = 6,
    NIMFFI_MSG_CLOSED = 7          /* the context is gone; nothing more will come */
};

typedef struct {
    uint32_t struct_size;
    uint32_t kind;
    uint64_t seq;
    uint64_t id;
    uint64_t name_id;     /* FNV-1a 64 of the wire name */
    uint64_t aux;
    int32_t ret_code;
    uint32_t flags;
    const uint8_t* payload;   /* borrowed until the next poll on this ctx; never NULL */
    size_t len;
} NimFfiMsg;

/* name_id of an event or reverse-call wire name. */
static inline uint64_t logosdelivery_name_id(const char* wire)
{
    uint64_t h = 0xcbf29ce484222325ULL;
    for (; *wire; ++wire) h = (h ^ (uint64_t)(unsigned char)*wire) * 0x100000001b3ULL;
    return h;
}

/* Lifecycle. The constructor returns the context at once; its REPLY (id_out)
 * says whether the node came up. */
int logosdelivery_create_node(const uint8_t* req, size_t len, void** ctx_out, uint64_t* id_out);
int logosdelivery_destroy(void* ctx);
int logosdelivery_shutdown(void);
int logosdelivery_poll(void* ctx, int32_t timeout_ms, const NimFfiMsg** msg);
int logosdelivery_poll_fd(void* ctx);
int logosdelivery_reverse_reply(void* ctx, uint64_t call_id, int ret,
                                const uint8_t* payload, size_t len);

/* Methods this module calls, with the CBOR map keys each expects. */
#define LOGOSDELIVERY_METHOD(name) \
    int name(void* ctx, const uint8_t* req, size_t len, uint64_t* id_out)
LOGOSDELIVERY_METHOD(logosdelivery_start_node);                  /* {} */
LOGOSDELIVERY_METHOD(logosdelivery_stop_node);                   /* {} */
LOGOSDELIVERY_METHOD(logosdelivery_send);                        /* {messageJson} */
LOGOSDELIVERY_METHOD(logosdelivery_subscribe);                   /* {contentTopicStr} */
LOGOSDELIVERY_METHOD(logosdelivery_unsubscribe);                 /* {contentTopicStr} */
LOGOSDELIVERY_METHOD(logosdelivery_channel_create);              /* {channelIdStr, contentTopicStr, senderIdStr} */
LOGOSDELIVERY_METHOD(logosdelivery_channel_exists);              /* {channelIdStr} */
LOGOSDELIVERY_METHOD(logosdelivery_channel_send);                /* {channelIdStr, messageJson} */
LOGOSDELIVERY_METHOD(logosdelivery_channel_close);               /* {channelIdStr} */
LOGOSDELIVERY_METHOD(logosdelivery_get_available_node_info_ids); /* {} */
LOGOSDELIVERY_METHOD(logosdelivery_get_node_info);               /* {nodeInfoId} */
LOGOSDELIVERY_METHOD(logosdelivery_get_available_configs);       /* {} */
LOGOSDELIVERY_METHOD(waku_store_query);                          /* {jsonQuery, peerAddr, timeoutMs} (kernel tier) */
#undef LOGOSDELIVERY_METHOD

#ifdef __cplusplus
}
#endif
