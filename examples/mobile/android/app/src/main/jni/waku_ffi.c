#include "liblogosdelivery_kernel.h"
#include <android/log.h>
#include <jni.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <pthread.h>

#define APPNAME "waku-jni"
#define LOGD(TAG) __android_log_print(ANDROID_LOG_DEBUG , APPNAME,TAG);

// cb_result represents a response received when executing a callback.
// If `error` is true, `message` will contain the error message description
// otherwise, it will contain the result of the callback execution
typedef struct {
  bool error;
  char *message;
} cb_result;

// cb_env is a struct passed as userdata when setting up the event callback.
// This is so we can pass the pointer back to kotlin to indicate which instance
// of waku received the message, and also so we can have access to `env` from
// within the event callback
typedef struct {
  jlong wakuPtr;
  JNIEnv *env;
} cb_env;

// frees the results associated to the allocation of a cb_result
void free_cb_result(cb_result *result) {
  if (result != NULL) {
    if (result->message != NULL) {
      free(result->message);
      result->message = NULL;
    }
    free(result);
    result = NULL;
  }
}

// The library answers on its own thread, so every call waits on a cb_wait
// until its reply has filled `result`.
typedef struct {
  pthread_mutex_t mtx;
  pthread_cond_t cond;
  bool done;
  cb_result *result;
  LogosDeliveryCtx *ctx;
} cb_wait;

static void wait_init(cb_wait *w) {
  pthread_mutex_init(&w->mtx, NULL);
  pthread_cond_init(&w->cond, NULL);
  w->done = false;
  w->result = NULL;
  w->ctx = NULL;
}

static void wait_reply(cb_wait *w) {
  pthread_mutex_lock(&w->mtx);
  while (!w->done)
    pthread_cond_wait(&w->cond, &w->mtx);
  pthread_mutex_unlock(&w->mtx);
  pthread_mutex_destroy(&w->mtx);
  pthread_cond_destroy(&w->cond);
}

static cb_result *new_cb_result(bool error, const char *text) {
  cb_result *res = malloc(sizeof(cb_result));
  res->error = error;
  res->message = strdup(text);
  return res;
}

static void complete(cb_wait *w, cb_result *res) {
  pthread_mutex_lock(&w->mtx);
  w->result = res;
  w->done = true;
  pthread_cond_signal(&w->cond);
  pthread_mutex_unlock(&w->mtx);
}

// LogosDelivery*ReplyFn: `reply` points at the reply text, or is NULL on
// failure, which `errMsg` then describes.
static void on_reply(int errCode, const char *const *reply, const char *errMsg,
                     void *user_data) {
  cb_wait *w = (cb_wait *)user_data;
  if (errCode != RET_OK) {
    char text[300];
    snprintf(text, sizeof(text),
             "function execution failed. Returned code: %d, %s", errCode,
             errMsg != NULL ? errMsg : "");
    complete(w, new_cb_result(true, text));
    return;
  }
  const char *text = (reply != NULL && *reply != NULL) ? *reply : "";
  complete(w, new_cb_result(false, text[0] != '\0' ? text : "on_response-ok"));
}

// LogosDeliveryCreateFn: a NULL result means success, as to_jni_ptr expects.
static void on_created(int errCode, LogosDeliveryCtx *ctx, const char *errMsg,
                       void *user_data) {
  cb_wait *w = (cb_wait *)user_data;
  w->ctx = ctx;
  complete(w, errCode == RET_OK
                  ? NULL
                  : new_cb_result(true, errMsg != NULL ? errMsg : "create failed"));
}

// Waits for the reply of a call that took `w` as user data. A call that
// fails up front has already replied through the callback.
static jobject finish_call(JNIEnv *env, cb_wait *w);

// converts a cb_result into an instance of the kotlin WakuResult class
jobject to_jni_result(JNIEnv *env, cb_result *result) {
  jclass myStructClass = (*env)->FindClass(env, "com/mobile/WakuResult");
  jmethodID constructor = (*env)->GetMethodID(env, myStructClass, "<init>",
                                              "(ZLjava/lang/String;)V");

  jboolean error;
  jstring message;
  if (result != NULL) {
    error = result->error;
    message = (*env)->NewStringUTF(env, result->message);
  } else {
    error = false;
    message = (*env)->NewStringUTF(env, "ok");
  }

  jobject response =
      (*env)->NewObject(env, myStructClass, constructor, error, message);

  // Free the intermediate message var
  (*env)->DeleteLocalRef(env, message);

  return response;
}

// converts a cb_result into an instance of the kotlin WakuPtr class
jobject to_jni_ptr(JNIEnv *env, cb_result *result, void *ptr) {
  jclass myStructClass = (*env)->FindClass(env, "com/mobile/WakuPtr");
  jmethodID constructor = (*env)->GetMethodID(env, myStructClass, "<init>",
                                              "(ZLjava/lang/String;J)V");

  jboolean error;
  jstring message;
  jlong wakuPtr;
  if (result != NULL) {
    error = result->error;
    message = (*env)->NewStringUTF(env, result->message);
    wakuPtr = -1;
  } else {
    error = false;
    message = (*env)->NewStringUTF(env, "ok");
    wakuPtr = (jlong)ptr;
  }

  jobject response = (*env)->NewObject(env, myStructClass, constructor, error,
                                       message, wakuPtr);

  // Free the intermediate message var
  (*env)->DeleteLocalRef(env, message);

  return response;
}

// libwaku functions
// ============================================================================

// JVM, required for executing JNI functions in a third party thread.
JavaVM *jvm;
static jobject jClassLoader;
static jmethodID jLoadClass;

JNIEnv *getEnv() {
  JNIEnv *env;
  int status = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
  if (status < 0) {
    status = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
    assert(status == JNI_OK && "could not obtain env");
  }
  return env;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *pjvm, void *reserved) {
  jvm = pjvm; // cache the JavaVM pointer
  JNIEnv *env = getEnv();

  jclass jLibraryClass =
      (*env)->FindClass(env, "com/mobile/EventCallbackManager");
  jclass jClassRef = (*env)->GetObjectClass(env, jLibraryClass);
  jclass jClassLoaderClass = (*env)->FindClass(env, "java/lang/ClassLoader");
  jmethodID getClassLoader = (*env)->GetMethodID(
      env, jClassRef, "getClassLoader", "()Ljava/lang/ClassLoader;");

  jobject jClassLoaderLocal =
      (*env)->CallObjectMethod(env, jLibraryClass, getClassLoader);
  jLoadClass = (*env)->GetMethodID(env, jClassLoaderClass, "loadClass",
                                   "(Ljava/lang/String;)Ljava/lang/Class;");
  jClassLoader = (*env)->NewGlobalRef(env, jClassLoaderLocal);

  (*env)->DeleteLocalRef(env, jClassLoaderLocal);
  (*env)->DeleteLocalRef(env, jClassLoaderClass);
  (*env)->DeleteLocalRef(env, jClassRef);
  (*env)->DeleteLocalRef(env, jLibraryClass);

  return JNI_VERSION_1_6;
}

jclass loadClass(JNIEnv *env, const char *className) {
  jstring jName = (*env)->NewStringUTF(env, className);
  jclass jClass = (*env)->CallObjectMethod(env, jClassLoader, jLoadClass, jName);
  assert((*env)->ExceptionCheck(env) == JNI_FALSE && "class could not be loaded");
  (*env)->DeleteLocalRef(env, jName);
  return jClass;
}

void Java_com_mobile_WakuModule_wakuSetup(JNIEnv *env, jobject thiz) {
  LOGD("log example for debugging purposes...")
}

static jobject finish_call(JNIEnv *env, cb_wait *w) {
  wait_reply(w);
  jobject response = to_jni_result(env, w->result);
  free_cb_result(w->result);
  return response;
}

#define CTX(p) ((const LogosDeliveryCtx *)(p))

jobject Java_com_mobile_WakuModule_wakuNew(JNIEnv *env, jobject thiz,
                                           jstring configJson) {
  const char *config = (*env)->GetStringUTFChars(env, configJson, 0);
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_create(config, on_created, &w);
  wait_reply(&w);
  jobject response = to_jni_ptr(env, w.result, w.ctx);
  (*env)->ReleaseStringUTFChars(env, configJson, config);
  free_cb_result(w.result);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuStart(JNIEnv *env, jobject thiz,
                                             jlong wakuPtr) {
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_start_node(CTX(wakuPtr), on_reply, &w);
  return finish_call(env, &w);
}

jobject Java_com_mobile_WakuModule_wakuVersion(JNIEnv *env, jobject thiz,
                                               jlong wakuPtr) {
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_version(CTX(wakuPtr), on_reply, &w);
  return finish_call(env, &w);
}

jobject Java_com_mobile_WakuModule_wakuStop(JNIEnv *env, jobject thiz,
                                            jlong wakuPtr) {
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_stop_node(CTX(wakuPtr), on_reply, &w);
  return finish_call(env, &w);
}

jobject Java_com_mobile_WakuModule_wakuDestroy(JNIEnv *env, jobject thiz,
                                               jlong wakuPtr) {
  logosdelivery_ctx_destroy((LogosDeliveryCtx *)wakuPtr);
  return to_jni_result(env, NULL);
}

jobject Java_com_mobile_WakuModule_wakuConnect(JNIEnv *env, jobject thiz,
                                               jlong wakuPtr,
                                               jstring peerMultiAddr,
                                               jint timeoutMs) {
  const char *peer = (*env)->GetStringUTFChars(env, peerMultiAddr, 0);
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_connect(CTX(wakuPtr), peer, (uint32_t)timeoutMs,
                                 on_reply, &w);
  jobject response = finish_call(env, &w);
  (*env)->ReleaseStringUTFChars(env, peerMultiAddr, peer);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuListenAddresses(JNIEnv *env,
                                                       jobject thiz,
                                                       jlong wakuPtr) {
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_listen_addresses(CTX(wakuPtr), on_reply, &w);
  return finish_call(env, &w);
}

jobject Java_com_mobile_WakuModule_wakuRelayPublish(JNIEnv *env, jobject thiz,
                                                    jlong wakuPtr,
                                                    jstring pubsubTopic,
                                                    jstring jsonWakuMessage,
                                                    jint timeoutMs) {
  const char *topic = (*env)->GetStringUTFChars(env, pubsubTopic, 0);
  const char *msg = (*env)->GetStringUTFChars(env, jsonWakuMessage, 0);
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_relay_publish(CTX(wakuPtr), topic, msg,
                                       (uint32_t)timeoutMs, on_reply, &w);
  jobject response = finish_call(env, &w);
  (*env)->ReleaseStringUTFChars(env, pubsubTopic, topic);
  (*env)->ReleaseStringUTFChars(env, jsonWakuMessage, msg);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuRelaySubscribe(JNIEnv *env, jobject thiz,
                                                      jlong wakuPtr,
                                                      jstring pubsubTopic) {
  const char *topic = (*env)->GetStringUTFChars(env, pubsubTopic, 0);
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_relay_subscribe(CTX(wakuPtr), topic, on_reply, &w);
  jobject response = finish_call(env, &w);
  (*env)->ReleaseStringUTFChars(env, pubsubTopic, topic);
  return response;
}

jobject Java_com_mobile_WakuModule_wakuRelayUnsubscribe(JNIEnv *env,
                                                        jobject thiz,
                                                        jlong wakuPtr,
                                                        jstring pubsubTopic) {
  const char *topic = (*env)->GetStringUTFChars(env, pubsubTopic, 0);
  cb_wait w;
  wait_init(&w);
  logosdelivery_ctx_waku_relay_unsubscribe(CTX(wakuPtr), topic, on_reply, &w);
  jobject response = finish_call(env, &w);
  (*env)->ReleaseStringUTFChars(env, pubsubTopic, topic);
  return response;
}

void wk_callback(int callerRet, const char *msg, size_t len, void *userData) {
  cb_env *c = (cb_env *)userData;

  // TODO: might be too much overhead to attach/detach per call?
  JNIEnv *env = c->env;
  JNIEnv *attachedEnv = NULL;
  assert((*jvm)->AttachCurrentThread(jvm, &attachedEnv, NULL) == JNI_OK && "could not attach to current thread");

  jclass clazz = loadClass(attachedEnv, "com/mobile/EventCallbackManager");

  jmethodID methodID =
      (*attachedEnv)
          ->GetStaticMethodID(attachedEnv, clazz, "execEventCallback", "(JLjava/lang/String;)V");

  jstring message = (*attachedEnv)->NewStringUTF(attachedEnv, msg);
  (*attachedEnv)->CallStaticVoidMethod(attachedEnv, clazz, methodID, c->wakuPtr, message);

  (*attachedEnv)->DeleteLocalRef(attachedEnv, clazz);

  (*attachedEnv)->DeleteLocalRef(attachedEnv, message);

  (*jvm)->DetachCurrentThread(jvm);
}

void Java_com_mobile_WakuModule_wakuSetEventCallback(JNIEnv *env, jobject thiz,
                                                     jlong wakuPtr) {
  cb_env *c = (cb_env *)malloc(sizeof(cb_env));
  c->wakuPtr = wakuPtr;
  c->env = env;
  static const char *kEventNames[] = {
      "onMessageSent",            "onMessageError",
      "onMessagePropagated",      "onMessageReceived",
      "onConnectionStatusChange", "onTopicHealthChange",
      "onConnectionChange",       "onReceivedMessage",
      "onChannelMessageReceived", "onChannelMessageSent",
      "onChannelMessageError"};
  for (size_t i = 0; i < sizeof(kEventNames) / sizeof(kEventNames[0]); i++)
    logosdelivery_add_event_listener(CTX(wakuPtr)->ptr, kEventNames[i], wk_callback,
                                     (void *)c);
}
