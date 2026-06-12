#include <assert.h>
#include <node_api.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../cbindings/base64.h"
#include "../../liblogosdelivery/liblogosdelivery.h"

// Reference to the NodeJs function to be called when a waku event occurs.
// static napi_ref ref_event_callback = NULL;
static napi_ref ref_version_callback = NULL;
static napi_ref ref_def_pubsub_topic_callback = NULL;
static napi_ref ref_on_error_callback = NULL;
static napi_threadsafe_function thsafe_fn = NULL;

// As a convenience, wrap N-API calls such that they cause Node.js to abort
// when they are unsuccessful.
#define NAPI_CALL(call)                                                    \
do {                                                                       \
  napi_status status = call;                                               \
  if (status != napi_ok) {                                                 \
    napi_fatal_error(#call, NAPI_AUTO_LENGTH, "failed", NAPI_AUTO_LENGTH); \
  }                                                                        \
} while (0)

#define WAKU_CALL(call)                                                        \
do {                                                                           \
  int ret = call;                                                              \
  if (ret != 0) {                                                              \
    char msg[128];                                                             \
    snprintf(msg, 128, "WAKU_CALL failed with code %d", ret);                  \
    napi_fatal_error(#call, NAPI_AUTO_LENGTH, "failed", NAPI_AUTO_LENGTH);     \
  }                                                                            \
} while (0)

// libwaku Context
void* ctx;

// For the case of C language we don't need to store a particular userData
void* userData = NULL;

static napi_env my_env;

// This function is responsible for converting data coming in from the worker
// thread to napi_value items that can be passed into JavaScript, and for
// calling the JavaScript function.
static void CallJs(napi_env env, napi_value js_cb, void* context, void* data) {

  // This parameter is not used.
  (void) context;
  // napi_status status;

  // Retrieve the message item created by the worker thread.
  char* msg = (char*) data;

  // env and js_cb may both be NULL if Node.js is in its cleanup phase, and
  // items are left over from earlier thread-safe calls from the worker thread.
  // When env is NULL, we simply skip over the call into Javascript and free the
  // items.
  if (env != NULL) {
    napi_value undefined;

    // Convert the integer to a napi_value.
    napi_value napi_msg;
    NAPI_CALL(napi_create_string_utf8(my_env,
                                      msg,
                                      NAPI_AUTO_LENGTH,
                                      &napi_msg));

    // Retrieve the JavaScript `undefined` value so we can use it as the `this`
    // value of the JavaScript function call.
    NAPI_CALL(napi_get_undefined(env, &undefined));

    // Call the JavaScript function and pass it the message generated in the 
    // working thread.
    NAPI_CALL(napi_call_function(env,
                                 undefined,
                                 js_cb,
                                 1,
                                 &napi_msg,
                                 NULL));
  }

  // Free the item created by the worker thread.
  free(data);
}

void handle_waku_version(int callerRet, const char* msg, size_t len) {
  if (ref_version_callback == NULL) {
    napi_throw_type_error(my_env, NULL, "ERROR in event_handler. ref_version_callback == NULL");
  }

  napi_value callback;
  NAPI_CALL(napi_get_reference_value(my_env, ref_version_callback, &callback));

  size_t argc = 2;
  napi_value napi_msg;
  NAPI_CALL(napi_create_string_utf8(my_env,
                                    msg,
                                    NAPI_AUTO_LENGTH,
                                    &napi_msg));
  napi_value napi_len;
  NAPI_CALL(napi_create_int32(my_env,
                              len,
                              &napi_len));

  napi_value global;
  NAPI_CALL(napi_get_global(my_env, &global));
  NAPI_CALL(napi_call_function(my_env, global, callback, argc, &napi_msg, NULL));
}

// This function is directly passed as a callback to the libwaku and it
// calls a NodeJs function if it has been set.
void event_handler(int callerRet, const char* msg, size_t len) {
  if (thsafe_fn == NULL) {
  // if (ref_event_callback == NULL) {
    napi_throw_type_error(my_env, NULL, "ERROR in event_handler. ref_event_callback == NULL");
  }

  char* allocated_msg = malloc(len + 1);
  strcpy(allocated_msg, msg);

  NAPI_CALL(napi_call_threadsafe_function(thsafe_fn, allocated_msg, napi_tsfn_nonblocking));
}

void handle_error(int callerRet, const char* msg, size_t len) {
  if (ref_on_error_callback == NULL) {
    napi_throw_type_error(my_env, NULL, "ERROR in event_handler. ref_on_error_callback == NULL");
  }

  napi_value callback;
  NAPI_CALL(napi_get_reference_value(my_env,
                                     ref_on_error_callback,
                                     &callback));
  size_t argc = 2;
  napi_value napi_msg;
  NAPI_CALL(napi_create_string_utf8(my_env,
                                    msg,
                                    NAPI_AUTO_LENGTH,
                                    &napi_msg));
  napi_value global;
  NAPI_CALL(napi_get_global(my_env, &global));
  NAPI_CALL(napi_call_function(my_env, global, callback, argc, &napi_msg, NULL));
}

char* contentTopic = NULL;
void handle_content_topic(int callerRet, const char* msg, size_t len) {
    if (contentTopic != NULL) {
        free(contentTopic);
    }

    contentTopic = malloc(len * sizeof(char) + 1);
    strcpy(contentTopic, msg);
}

void handle_default_pubsub_topic(int callerRet, const char* msg, size_t len) {
  if (ref_def_pubsub_topic_callback == NULL) {
    napi_throw_type_error(my_env, NULL,
           "ERROR in event_handler. ref_def_pubsub_topic_callback == NULL");
  }

  napi_value callback;
  NAPI_CALL(napi_get_reference_value(my_env,
                                     ref_def_pubsub_topic_callback,
                                     &callback));
  size_t argc = 2;
  napi_value napi_msg;
  NAPI_CALL(napi_create_string_utf8(my_env,
                                    msg,
                                    NAPI_AUTO_LENGTH,
                                    &napi_msg));
  napi_value napi_len;
  NAPI_CALL(napi_create_int32(my_env,
                              len,
                              &napi_len));

  napi_value global;
  NAPI_CALL(napi_get_global(my_env, &global));
  NAPI_CALL(napi_call_function(my_env, global, callback, argc, &napi_msg, NULL));
}

// The next should be called always, at the beginning
static napi_value WakuNew(napi_env env, napi_callback_info info) {

  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 1) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  size_t str_size;
  size_t str_size_read;
  napi_get_value_string_utf8(env, args[0], NULL, 0, &str_size);
  char* jsonConfig;
  jsonConfig = malloc(str_size + 1);
  str_size = str_size + 1;
  napi_get_value_string_utf8(env, args[0], jsonConfig, str_size, &str_size_read);

  ctx = waku_new(jsonConfig, event_handler, userData);

  free(jsonConfig);

  return NULL;
}

static napi_value WakuVersion(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 1) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  napi_value cb = args[0];

  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  my_env = env;
  if(ref_version_callback != NULL) {
    NAPI_CALL(napi_delete_reference(env, ref_version_callback));
  }

  NAPI_CALL(napi_create_reference(env, cb, 1, &ref_version_callback));

  WAKU_CALL( waku_version(ctx, handle_waku_version, userData) );

  return NULL;
}

static napi_value WakuSetEventCallback(napi_env env, napi_callback_info info) {

  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 1) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  napi_value cb = args[0];

  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  my_env = env;

  napi_value work_name;
  NAPI_CALL(napi_create_string_utf8(env,
                                    "worker_name",
                                    NAPI_AUTO_LENGTH,
                                    &work_name));

  NAPI_CALL(
    napi_create_threadsafe_function(env,
                                    cb,
                                    NULL,
                                    work_name,
                                    0,
                                    1,
                                    NULL,
                                    NULL,
                                    NULL,
                                    CallJs, // the C/C++ callback function
      // out: the asynchronous thread-safe JavaScript function
                                    &thsafe_fn));

  // Inside 'event_handler', the event will be dispatched to the NodeJs
  // if there is a proper napi_function (ref_event_callback) being set.
  logosdelivery_set_event_callback(event_handler, userData);

  return NULL;
}

static napi_value WakuStart(napi_env env, napi_callback_info info) {
  waku_start(ctx, event_handler, userData);
  return NULL;
}

static napi_value WakuConnect(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 3) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  // Getting the peers param
  napi_value napiPeers = args[0];
  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, napiPeers, &valueType));

  if (valueType != napi_string) {
    napi_throw_type_error(env, NULL, "The peers attribute should be a string");
    return NULL;
  }

  size_t str_size;
  size_t str_size_read;
  napi_get_value_string_utf8(env, napiPeers, NULL, 0, &str_size);
  char* peers;
  peers = malloc(str_size + 1);
  str_size = str_size + 1;
  napi_get_value_string_utf8(env, napiPeers, peers, str_size, &str_size_read);

  // Getting the timeout param
  napi_value napiTimeout = args[1];
  NAPI_CALL(napi_typeof(env, napiTimeout, &valueType));

  if (valueType != napi_number) {
    napi_throw_type_error(env, NULL, "The timeout attribute should be a number");
    return NULL;
  }

  int32_t timeoutMs;
  NAPI_CALL(napi_get_value_int32(env, napiTimeout, &timeoutMs));

  // Getting the 'onError' callback
  napi_value cb = args[2];

  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  my_env = env;
  NAPI_CALL(napi_create_reference(env, cb, 1, &ref_on_error_callback));

  WAKU_CALL(waku_connect(ctx, peers, timeoutMs, handle_error, userData));

  // Free allocated memory
  free(peers);

  return NULL;
}

static napi_value WakuRelayPublish(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 5) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  // pubsubtopic
  napi_value napiPubsubTopic = args[0];
  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, napiPubsubTopic, &valueType));

  if (valueType != napi_string) {
    napi_throw_type_error(env, NULL, "The napiPubsubTopic attribute should be a string");
    return NULL;
  }

  size_t str_size;
  size_t str_size_read;
  napi_get_value_string_utf8(env, napiPubsubTopic, NULL, 0, &str_size);
  char* pubsub_topic;
  pubsub_topic = malloc(str_size + 1);
  str_size = str_size + 1;
  napi_get_value_string_utf8(env, napiPubsubTopic, pubsub_topic, str_size, &str_size_read);

  // content topic
  napi_value napiContentTopic = args[1];
  NAPI_CALL(napi_typeof(env, napiContentTopic, &valueType));

  if (valueType != napi_string) {
    napi_throw_type_error(env, NULL, "The content topic attribute should be a string");
    return NULL;
  }

  napi_get_value_string_utf8(env, napiContentTopic, NULL, 0, &str_size);
  char* content_topic_name = malloc(str_size + 1);
  str_size = str_size + 1;
  napi_get_value_string_utf8(env, napiContentTopic, content_topic_name, str_size, &str_size_read);

  // message
  napi_value napiMessage = args[2];
  NAPI_CALL(napi_typeof(env, napiMessage, &valueType));

  if (valueType != napi_string) {
    napi_throw_type_error(env, NULL, "The message attribute should be a string");
    return NULL;
  }

  char msg[2048];
  // TODO: check the correct message size limit
  size_t lengthMsg;
  NAPI_CALL(napi_get_value_string_utf8(env,
                                       napiMessage,
                                       msg,
                                       2048,
                                       &lengthMsg));
  char jsonWakuMsg[1024];
  char *msgPayload = b64_encode((unsigned char*) msg, strlen(msg));

  // TODO: move all the 'waku_content_topic' logic inside the libwaku
  WAKU_CALL( waku_content_topic(ctx,
                                "appName",
                                1,
                                content_topic_name,
                                "encoding",
                                handle_content_topic,
                                userData) );
  snprintf(jsonWakuMsg,
           1024,
           "{\"payload\":\"%s\",\"content_topic\":\"%s\"}",
           msgPayload, contentTopic);
  free(msgPayload);

  // Getting the timeout parameter
  unsigned int timeoutMs;
  napi_value timeout = args[3];

  NAPI_CALL(napi_typeof(env, timeout, &valueType));

  if (valueType != napi_number) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_number");
    return NULL;
  }

  NAPI_CALL(napi_get_value_int64(env, timeout, (int64_t *) &timeoutMs)); 

  // Getting the 'onError' callback
  napi_value cb = args[4];

  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  NAPI_CALL(napi_create_reference(env, cb, 1, &ref_on_error_callback));

  // Perform the actual 'publish'
  WAKU_CALL( waku_relay_publish(ctx,
                                pubsub_topic,
                                jsonWakuMsg,
                                timeoutMs,
                                handle_error,
                                userData) );
  free(pubsub_topic);
  free(content_topic_name);

  return NULL;
}

static napi_value WakuDefaultPubsubTopic(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 1) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  napi_value cb = args[0];

  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  my_env = env;
  if(ref_def_pubsub_topic_callback != NULL) {
    NAPI_CALL(napi_delete_reference(env, ref_def_pubsub_topic_callback));
  }

  NAPI_CALL(napi_create_reference(env, cb, 1, &ref_def_pubsub_topic_callback));

  WAKU_CALL( waku_default_pubsub_topic(ctx, handle_default_pubsub_topic, userData) );

  return NULL;
}

static napi_value WakuRelaySubscribe(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  NAPI_CALL(napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (argc < 2) {
    napi_throw_type_error(env, NULL, "Wrong number of arguments");
    return NULL;
  }

  // Getting the pubsub topic param
  napi_value topic = args[0];
  napi_valuetype valueType;
  NAPI_CALL(napi_typeof(env, topic, &valueType));

  if (valueType != napi_string) {
    napi_throw_type_error(env, NULL, "The topic attribute should be a string");
    return NULL;
  }

  size_t str_size;
  size_t str_size_read;
  napi_get_value_string_utf8(env, topic, NULL, 0, &str_size);
  char* pubsub_topic;
  pubsub_topic = malloc(str_size + 1);
  str_size = str_size + 1;
  napi_get_value_string_utf8(env, topic, pubsub_topic, str_size, &str_size_read);

  // Getting the 'onError' callback
  napi_value cb = args[1];

  NAPI_CALL(napi_typeof(env, cb, &valueType));

  if (valueType != napi_function) {
    napi_throw_type_error(env, NULL, "The argument should be a napi_function");
    return NULL;
  }

  my_env = env;
  NAPI_CALL(napi_create_reference(env, cb, 1, &ref_on_error_callback));

  // Calling the actual 'subscribe' waku function
  WAKU_CALL( waku_relay_subscribe(ctx, pubsub_topic, handle_error, userData) );

  free(pubsub_topic);

  return NULL;
}

#define DECLARE_NAPI_METHOD(name, func)                                        \
  { name, 0, func, 0, 0, 0, napi_default, 0 }

static napi_value Init(napi_env env, napi_value exports) {
  // DECLARE_NAPI_METHOD("<function_name_in_NodeJs>", <function_name_in_waku_wrapper.c>);

  napi_property_descriptor wakuVersion = DECLARE_NAPI_METHOD("wakuVersion", WakuVersion);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuVersion));

  napi_property_descriptor wakuNew = DECLARE_NAPI_METHOD("wakuNew", WakuNew);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuNew));

  napi_property_descriptor wakuStart = DECLARE_NAPI_METHOD("wakuStart", WakuStart);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuStart));

  napi_property_descriptor wakuSetEventCallback = DECLARE_NAPI_METHOD("wakuSetEventCallback", WakuSetEventCallback);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuSetEventCallback));

  napi_property_descriptor wakuDefaultPubsubTopic = DECLARE_NAPI_METHOD("wakuDefaultPubsubTopic", WakuDefaultPubsubTopic);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuDefaultPubsubTopic));

  napi_property_descriptor wakuRelaySubscribe = DECLARE_NAPI_METHOD("wakuRelaySubscribe", WakuRelaySubscribe);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuRelaySubscribe));

  napi_property_descriptor wakuConnect = DECLARE_NAPI_METHOD("wakuConnect", WakuConnect);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuConnect));

  napi_property_descriptor wakuRelayPublish = DECLARE_NAPI_METHOD("wakuRelayPublish", WakuRelayPublish);
  NAPI_CALL(napi_define_properties(env, exports, 1, &wakuRelayPublish));

  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
