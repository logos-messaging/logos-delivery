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
#include "nim_ffi.h" /* the poll model itself, installed from nim-ffi's host/ beside this file */

#ifdef __cplusplus
extern "C" {
#endif

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
