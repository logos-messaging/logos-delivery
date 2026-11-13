package main

/*
	#cgo CFLAGS: -I${SRCDIR}/../../build
	#cgo LDFLAGS: -L${SRCDIR}/../../build -llogosdelivery -Wl,-rpath,${SRCDIR}/../../build

	#include "liblogosdelivery_kernel.h"
	#include <stdio.h>
	#include <stdlib.h>
	#include <string.h>
	#include <pthread.h>

	extern void globalEventCallback(int ret, char* msg, size_t len, void* userData);

	// The library answers on its own thread, so a Resp carries the handshake
	// as well as the payload. `msg` is owned here: the buffer handed to a
	// callback is only valid for that call.
	typedef struct {
		int ret;
		char* msg;
		size_t len;
		int done;
		pthread_mutex_t mtx;
		pthread_cond_t cond;
	} Resp;

	static void* allocResp() {
		Resp* r = calloc(1, sizeof(Resp));
		pthread_mutex_init(&r->mtx, NULL);
		pthread_cond_init(&r->cond, NULL);
		return r;
	}

	static void freeResp(void* resp) {
		if (resp != NULL) {
			Resp* r = (Resp*) resp;
			pthread_mutex_destroy(&r->mtx);
			pthread_cond_destroy(&r->cond);
			free(r->msg);
			free(r);
		}
	}

	// Blocks until the reply lands. Without this the caller reads a zeroed
	// Resp, and since RET_OK is 0 that looks like success with an empty body.
	static void waitResp(void* resp) {
		if (resp == NULL) {
			return;
		}
		Resp* m = (Resp*) resp;
		pthread_mutex_lock(&m->mtx);
		while (!m->done) {
			pthread_cond_wait(&m->cond, &m->mtx);
		}
		pthread_mutex_unlock(&m->mtx);
	}

	static void completeResp(Resp* m, int ret, const char* text, size_t len) {
		pthread_mutex_lock(&m->mtx);
		m->ret = ret;
		free(m->msg);
		m->msg = malloc(len + 1);
		if (m->msg != NULL) {
			if (len > 0 && text != NULL) {
				memcpy(m->msg, text, len);
			}
			m->msg[len] = '\0';
			m->len = len;
		}
		m->done = 1;
		pthread_cond_signal(&m->cond);
		pthread_mutex_unlock(&m->mtx);
	}

	static char* getMyCharPtr(void* resp) {
		if (resp == NULL) {
			return NULL;
		}
		Resp* m = (Resp*) resp;
		return m->msg;
	}

	static size_t getMyCharLen(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->len;
	}

	static int getRet(void* resp) {
		if (resp == NULL) {
			return 0;
		}
		Resp* m = (Resp*) resp;
		return m->ret;
	}

	// LogosDelivery*ReplyFn: `reply` points at the reply text, or is NULL on
	// failure, which `errMsg` then describes.
	static void replyCallback(int errCode, const char* const* reply, const char* errMsg, void* resp) {
		if (resp != NULL) {
			const char* text = (reply != NULL && *reply != NULL) ? *reply : (errMsg != NULL ? errMsg : "");
			completeResp((Resp*) resp, errCode, text, strlen(text));
		}
	}

	typedef struct {
		Resp* resp;
		LogosDeliveryCtx* ctx;
	} CreateResp;

	static void createCallback(int errCode, LogosDeliveryCtx* ctx, const char* errMsg, void* userData) {
		CreateResp* c = (CreateResp*) userData;
		c->ctx = ctx;
		const char* text = errMsg != NULL ? errMsg : "";
		completeResp(c->resp, errCode, text, strlen(text));
	}

	#define LOGOS_DELIVERY_CALL(call)                                                        \
	do {                                                                           \
		int ret = call;                                                              \
		if (ret != 0) {                                                              \
			printf("Failed the call to: %s. Returned code: %d\n", #call, ret);         \
			exit(1);                                                                   \
		}                                                                            \
	} while (0)

	// The Go side keeps the LogosDeliveryCtx* as an opaque void*.
	#define CTX(p) ((const LogosDeliveryCtx*) (p))

	static void* cGoLogosDeliveryNew(const char* configJson, void* resp) {
		CreateResp c = {.resp = (Resp*) resp, .ctx = NULL};
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_create(configJson, createCallback, &c));
		waitResp(resp);
		return c.ctx;
	}

	static void cGoLogosDeliveryStart(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_start_node(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryStop(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_stop_node(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryDestroy(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_destroy((LogosDeliveryCtx*) logosDeliveryCtx));
	}

	static void cGoLogosDeliveryStartDiscV5(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_waku_start_discv5(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryStopDiscV5(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_waku_stop_discv5(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryVersion(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL(logosdelivery_ctx_waku_version(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliverySetEventCallback(void* logosDeliveryCtx) {
		// The 'globalEventCallback' Go function is shared amongst all possible Logos Delivery instances.

		// Given that the 'globalEventCallback' is shared, we pass again the
		// logosDeliveryCtx instance but in this case is needed to pick up the correct method
		// that will handle the event.

		// In other words, for every call the liblogosdelivery makes to globalEventCallback,
		// the 'userData' parameter will bring the context of the node that registered
		// that globalEventCallback.

		// This technique is needed because cgo only allows to export Go functions and not methods.

		static const char* eventNames[] = {
			"onMessageSent", "onMessageError", "onMessagePropagated",
			"onMessageReceived", "onConnectionStatusChange", "onTopicHealthChange",
			"onConnectionChange", "onReceivedMessage", "onChannelMessageReceived",
			"onChannelMessageSent", "onChannelMessageError"};
		for (size_t i = 0; i < sizeof(eventNames) / sizeof(eventNames[0]); i++) {
			logosdelivery_add_event_listener(CTX(logosDeliveryCtx)->ptr, eventNames[i], (FFICallBack) globalEventCallback, logosDeliveryCtx);
		}
	}

	static void cGoLogosDeliveryContentTopic(void* logosDeliveryCtx,
							char* appName,
							int appVersion,
							char* contentTopicName,
							char* encoding,
							void* resp) {

		LOGOS_DELIVERY_CALL( logosdelivery_ctx_waku_content_topic(CTX(logosDeliveryCtx), appName, appVersion, contentTopicName, encoding, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryPubsubTopic(void* logosDeliveryCtx, char* topicName, void* resp) {
		LOGOS_DELIVERY_CALL( logosdelivery_ctx_waku_pubsub_topic(CTX(logosDeliveryCtx), topicName, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryDefaultPubsubTopic(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_default_pubsub_topic(CTX(logosDeliveryCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryRelayPublish(void* logosDeliveryCtx,
                       const char* pubSubTopic,
                       const char* jsonWakuMessage,
                       int timeoutMs,
					   void* resp) {

		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_relay_publish(CTX(logosDeliveryCtx), pubSubTopic, jsonWakuMessage, timeoutMs, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryRelaySubscribe(void* logosDeliveryCtx, char* pubSubTopic, void* resp) {
		LOGOS_DELIVERY_CALL ( logosdelivery_ctx_waku_relay_subscribe(CTX(logosDeliveryCtx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryRelayUnsubscribe(void* logosDeliveryCtx, char* pubSubTopic, void* resp) {
		LOGOS_DELIVERY_CALL ( logosdelivery_ctx_waku_relay_unsubscribe(CTX(logosDeliveryCtx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryConnect(void* logosDeliveryCtx, char* peerMultiAddr, int timeoutMs, void* resp) {
		LOGOS_DELIVERY_CALL( logosdelivery_ctx_waku_connect(CTX(logosDeliveryCtx), peerMultiAddr, timeoutMs, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryDialPeerById(void* logosDeliveryCtx,
									char* peerId,
									char* protocol,
									int timeoutMs,
									void* resp) {

		LOGOS_DELIVERY_CALL( logosdelivery_ctx_waku_dial_peer_by_id(CTX(logosDeliveryCtx), peerId, protocol, timeoutMs, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryDisconnectPeerById(void* logosDeliveryCtx, char* peerId, void* resp) {
		LOGOS_DELIVERY_CALL( logosdelivery_ctx_waku_disconnect_peer_by_id(CTX(logosDeliveryCtx), peerId, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryListenAddresses(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_listen_addresses(CTX(logosDeliveryCtx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryGetMyENR(void* ctx, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_get_my_enr(CTX(ctx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryGetMyPeerId(void* ctx, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_get_my_peerid(CTX(ctx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryListPeersInMesh(void* ctx, char* pubSubTopic, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_relay_get_num_peers_in_mesh(CTX(ctx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryGetNumConnectedPeers(void* ctx, char* pubSubTopic, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_relay_get_num_connected_peers(CTX(ctx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryGetPeerIdsFromPeerStore(void* logosDeliveryCtx, void* resp) {
		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_get_peerids_from_peerstore(CTX(logosDeliveryCtx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoLogosDeliveryLightpushPublish(void* logosDeliveryCtx,
					const char* pubSubTopic,
					const char* jsonWakuMessage,
					void* resp) {

		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_lightpush_publish(CTX(logosDeliveryCtx), pubSubTopic, jsonWakuMessage, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryStoreQuery(void* logosDeliveryCtx,
					const char* jsonQuery,
					const char* peerAddr,
					int timeoutMs,
					void* resp) {

		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_store_query(CTX(logosDeliveryCtx), jsonQuery, peerAddr, timeoutMs, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryPeerExchangeQuery(void* logosDeliveryCtx,
								uint64_t numPeers,
								void* resp) {

		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_peer_exchange_request(CTX(logosDeliveryCtx), numPeers, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoLogosDeliveryGetPeerIdsByProtocol(void* logosDeliveryCtx,
									 const char* protocol,
									 void* resp) {

		LOGOS_DELIVERY_CALL (logosdelivery_ctx_waku_get_peerids_by_protocol(CTX(logosDeliveryCtx), protocol, replyCallback, resp));
		waitResp(resp);
	}

*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"unsafe"
)

type WakuMessageHash = string
type LogosDeliveryPubsubTopic = string
type LogosDeliveryContentTopic = string

type MessagingOverrides struct {
	ListenAddress string `json:"listen-address,omitempty"`
	Port          int    `json:"tcp-port,omitempty"`
	NodeKey       string `json:"nodekey,omitempty"`
	LogLevel      string `json:"log-level,omitempty"`
}

type LogosDeliveryConfig struct {
	Mode               string             `json:"mode"`
	MessagingOverrides MessagingOverrides `json:"messagingOverrides"`
}

type LogosDeliveryNode struct {
	ctx unsafe.Pointer
}

func LogosDeliveryNew(config LogosDeliveryConfig) (*LogosDeliveryNode, error) {
	jsonConfig, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}

	var cJsonConfig = C.CString(string(jsonConfig))
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cJsonConfig))
	defer C.freeResp(resp)

	ctx := C.cGoLogosDeliveryNew(cJsonConfig, resp)
	if C.getRet(resp) == C.RET_OK {
		return &LogosDeliveryNode{ctx: ctx}, nil
	}

	errMsg := "error LogosDeliveryNew: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return nil, errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryStart() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryStart(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryStart: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryStop() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryStop(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryStop: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryDestroy() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryDestroy(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryDestroy: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryVersion() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)

	C.cGoLogosDeliveryVersion(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var version = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return version, nil
	}

	errMsg := "error LogosDeliveryVersion: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := LogosDeliveryNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self *LogosDeliveryNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	fmt.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self *LogosDeliveryNode) LogosDeliverySetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoLogosDeliverySetEventCallback(self.ctx)
}

func (self *LogosDeliveryNode) FormatContentTopic(
	appName string,
	appVersion int,
	contentTopicName string,
	encoding string) (LogosDeliveryContentTopic, error) {

	var cAppName = C.CString(appName)
	var cContentTopicName = C.CString(contentTopicName)
	var cEncoding = C.CString(encoding)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cAppName))
	defer C.free(unsafe.Pointer(cContentTopicName))
	defer C.free(unsafe.Pointer(cEncoding))
	defer C.freeResp(resp)

	C.cGoLogosDeliveryContentTopic(self.ctx,
		cAppName,
		C.int(appVersion),
		cContentTopicName,
		cEncoding,
		resp)

	if C.getRet(resp) == C.RET_OK {
		var contentTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return contentTopic, nil
	}

	errMsg := "error FormatContentTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *LogosDeliveryNode) FormatPubsubTopic(topicName string) (LogosDeliveryPubsubTopic, error) {
	var cTopicName = C.CString(topicName)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cTopicName))
	defer C.freeResp(resp)

	C.cGoLogosDeliveryPubsubTopic(self.ctx, cTopicName, resp)
	if C.getRet(resp) == C.RET_OK {
		var pubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return pubsubTopic, nil
	}

	errMsg := "error FormatPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryDefaultPubsubTopic() (LogosDeliveryPubsubTopic, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryDefaultPubsubTopic(self.ctx, resp)
	if C.getRet(resp) == C.RET_OK {
		var defaultPubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return defaultPubsubTopic, nil
	}

	errMsg := "error LogosDeliveryDefaultPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryRelayPublish(
	pubsubTopic string,
	message string,
	timeoutMs int) (WakuMessageHash, error) {

	var cPubsubTopic = C.CString(pubsubTopic)
	var msg = C.CString(message)
	var resp = C.allocResp()

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	defer C.free(unsafe.Pointer(msg))

	C.cGoLogosDeliveryRelayPublish(self.ctx, cPubsubTopic, msg, C.int(timeoutMs), resp)
	if C.getRet(resp) == C.RET_OK {
		msgHash := C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return msgHash, nil
	}
	errMsg := "error LogosDeliveryRelayPublish: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryRelaySubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoLogosDeliveryRelaySubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryRelaySubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryRelayUnsubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoLogosDeliveryRelayUnsubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryRelayUnsubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryConnect(peerMultiAddr string, timeoutMs int) error {
	var resp = C.allocResp()
	var cPeerMultiAddr = C.CString(peerMultiAddr)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPeerMultiAddr))

	C.cGoLogosDeliveryConnect(self.ctx, cPeerMultiAddr, C.int(timeoutMs), resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error LogosDeliveryConnect: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryListenAddresses() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryListenAddresses(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var listenAddresses = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return listenAddresses, nil
	}
	errMsg := "error LogosDeliveryListenAddresses: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *LogosDeliveryNode) LogosDeliveryGetMyENR() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoLogosDeliveryGetMyENR(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var myENR = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return myENR, nil
	}
	errMsg := "error LogosDeliveryGetMyENR: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func main() {
	config := LogosDeliveryConfig{
		Mode: "Core",
		MessagingOverrides: MessagingOverrides{
			ListenAddress: "0.0.0.0",
			Port:          30304,
			NodeKey:       "11d0dcea28e86f81937a3bd1163473c7fbc0a0db54fd72914849bc47bdf78710",
			LogLevel:      "DEBUG",
		},
	}

	node, err := LogosDeliveryNew(config)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	node.LogosDeliverySetEventCallback()

	defaultPubsubTopic, err := node.LogosDeliveryDefaultPubsubTopic()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.LogosDeliveryRelaySubscribe(defaultPubsubTopic)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.LogosDeliveryConnect(
		// tries to connect to a localhost node with key: 0d714a1fada214dead6dc9c7274585eca0ff292451866e7d6d677dc818e8ccd2
		"/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN",
		10000)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.LogosDeliveryStart()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	version, err := node.LogosDeliveryVersion()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	formattedContentTopic, err := node.FormatContentTopic("appName", 1, "cTopicName", "enc")
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	formattedPubsubTopic, err := node.FormatPubsubTopic("my-ctopic")
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	listenAddresses, err := node.LogosDeliveryListenAddresses()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	myENR, err := node.LogosDeliveryGetMyENR()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	fmt.Println("Version:", version)
	fmt.Println("Custom content topic:", formattedContentTopic)
	fmt.Println("Custom pubsub topic:", formattedPubsubTopic)
	fmt.Println("Default pubsub topic:", defaultPubsubTopic)
	fmt.Println("Listen addresses:", listenAddresses)
	fmt.Println("My ENR:", myENR)

	// Wait for a SIGINT or SIGTERM signal
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch

	err = node.LogosDeliveryStop()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.LogosDeliveryDestroy()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}
}
