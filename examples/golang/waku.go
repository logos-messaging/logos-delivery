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

	#define WAKU_CALL(call)                                                        \
	do {                                                                           \
		int ret = call;                                                              \
		if (ret != 0) {                                                              \
			printf("Failed the call to: %s. Returned code: %d\n", #call, ret);         \
			exit(1);                                                                   \
		}                                                                            \
	} while (0)

	// The Go side keeps the LogosDeliveryCtx* as an opaque void*.
	#define CTX(p) ((const LogosDeliveryCtx*) (p))

	static void* cGoWakuNew(const char* configJson, void* resp) {
		CreateResp c = {.resp = (Resp*) resp, .ctx = NULL};
		WAKU_CALL(logosdelivery_ctx_create(configJson, createCallback, &c));
		waitResp(resp);
		return c.ctx;
	}

	static void cGoWakuStart(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_start_node(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuStop(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_stop_node(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuDestroy(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_destroy((LogosDeliveryCtx*) wakuCtx));
	}

	static void cGoWakuStartDiscV5(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_waku_start_discv5(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuStopDiscV5(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_waku_stop_discv5(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuVersion(void* wakuCtx, void* resp) {
		WAKU_CALL(logosdelivery_ctx_waku_version(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuSetEventCallback(void* wakuCtx) {
		// The 'globalEventCallback' Go function is shared amongst all possible Waku instances.

		// Given that the 'globalEventCallback' is shared, we pass again the
		// wakuCtx instance but in this case is needed to pick up the correct method
		// that will handle the event.

		// In other words, for every call the libwaku makes to globalEventCallback,
		// the 'userData' parameter will bring the context of the node that registered
		// that globalEventCallback.

		// This technique is needed because cgo only allows to export Go functions and not methods.

		static const char* eventNames[] = {
			"onMessageSent", "onMessageError", "onMessagePropagated",
			"onMessageReceived", "onConnectionStatusChange", "onTopicHealthChange",
			"onConnectionChange", "onReceivedMessage", "onChannelMessageReceived",
			"onChannelMessageSent", "onChannelMessageError"};
		for (size_t i = 0; i < sizeof(eventNames) / sizeof(eventNames[0]); i++) {
			logosdelivery_add_event_listener(CTX(wakuCtx)->ptr, eventNames[i], (FFICallBack) globalEventCallback, wakuCtx);
		}
	}

	static void cGoWakuContentTopic(void* wakuCtx,
							char* appName,
							int appVersion,
							char* contentTopicName,
							char* encoding,
							void* resp) {

		WAKU_CALL( logosdelivery_ctx_waku_content_topic(CTX(wakuCtx), appName, appVersion, contentTopicName, encoding, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuPubsubTopic(void* wakuCtx, char* topicName, void* resp) {
		WAKU_CALL( logosdelivery_ctx_waku_pubsub_topic(CTX(wakuCtx), topicName, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuDefaultPubsubTopic(void* wakuCtx, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_default_pubsub_topic(CTX(wakuCtx), replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuRelayPublish(void* wakuCtx,
                       const char* pubSubTopic,
                       const char* jsonWakuMessage,
                       int timeoutMs,
					   void* resp) {

		WAKU_CALL (logosdelivery_ctx_waku_relay_publish(CTX(wakuCtx), pubSubTopic, jsonWakuMessage, timeoutMs, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuRelaySubscribe(void* wakuCtx, char* pubSubTopic, void* resp) {
		WAKU_CALL ( logosdelivery_ctx_waku_relay_subscribe(CTX(wakuCtx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuRelayUnsubscribe(void* wakuCtx, char* pubSubTopic, void* resp) {
		WAKU_CALL ( logosdelivery_ctx_waku_relay_unsubscribe(CTX(wakuCtx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuConnect(void* wakuCtx, char* peerMultiAddr, int timeoutMs, void* resp) {
		WAKU_CALL( logosdelivery_ctx_waku_connect(CTX(wakuCtx), peerMultiAddr, timeoutMs, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuDialPeerById(void* wakuCtx,
									char* peerId,
									char* protocol,
									int timeoutMs,
									void* resp) {

		WAKU_CALL( logosdelivery_ctx_waku_dial_peer_by_id(CTX(wakuCtx), peerId, protocol, timeoutMs, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuDisconnectPeerById(void* wakuCtx, char* peerId, void* resp) {
		WAKU_CALL( logosdelivery_ctx_waku_disconnect_peer_by_id(CTX(wakuCtx), peerId, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuListenAddresses(void* wakuCtx, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_listen_addresses(CTX(wakuCtx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuGetMyENR(void* ctx, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_get_my_enr(CTX(ctx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuGetMyPeerId(void* ctx, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_get_my_peerid(CTX(ctx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuListPeersInMesh(void* ctx, char* pubSubTopic, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_relay_get_num_peers_in_mesh(CTX(ctx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuGetNumConnectedPeers(void* ctx, char* pubSubTopic, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_relay_get_num_connected_peers(CTX(ctx), pubSubTopic, replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuGetPeerIdsFromPeerStore(void* wakuCtx, void* resp) {
		WAKU_CALL (logosdelivery_ctx_waku_get_peerids_from_peerstore(CTX(wakuCtx), replyCallback, resp) );
		waitResp(resp);
	}

	static void cGoWakuLightpushPublish(void* wakuCtx,
					const char* pubSubTopic,
					const char* jsonWakuMessage,
					void* resp) {

		WAKU_CALL (logosdelivery_ctx_waku_lightpush_publish(CTX(wakuCtx), pubSubTopic, jsonWakuMessage, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuStoreQuery(void* wakuCtx,
					const char* jsonQuery,
					const char* peerAddr,
					int timeoutMs,
					void* resp) {

		WAKU_CALL (logosdelivery_ctx_waku_store_query(CTX(wakuCtx), jsonQuery, peerAddr, timeoutMs, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuPeerExchangeQuery(void* wakuCtx,
								uint64_t numPeers,
								void* resp) {

		WAKU_CALL (logosdelivery_ctx_waku_peer_exchange_request(CTX(wakuCtx), numPeers, replyCallback, resp));
		waitResp(resp);
	}

	static void cGoWakuGetPeerIdsByProtocol(void* wakuCtx,
									 const char* protocol,
									 void* resp) {

		WAKU_CALL (logosdelivery_ctx_waku_get_peerids_by_protocol(CTX(wakuCtx), protocol, replyCallback, resp));
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
type WakuPubsubTopic = string
type WakuContentTopic = string

type MessagingOverrides struct {
	ListenAddress string `json:"listen-address,omitempty"`
	Port          int    `json:"tcp-port,omitempty"`
	NodeKey       string `json:"nodekey,omitempty"`
	LogLevel      string `json:"log-level,omitempty"`
}

type WakuConfig struct {
	Mode               string             `json:"mode"`
	MessagingOverrides MessagingOverrides `json:"messagingOverrides"`
}

type WakuNode struct {
	ctx unsafe.Pointer
}

func WakuNew(config WakuConfig) (*WakuNode, error) {
	jsonConfig, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}

	var cJsonConfig = C.CString(string(jsonConfig))
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cJsonConfig))
	defer C.freeResp(resp)

	ctx := C.cGoWakuNew(cJsonConfig, resp)
	if C.getRet(resp) == C.RET_OK {
		return &WakuNode{ctx: ctx}, nil
	}

	errMsg := "error WakuNew: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return nil, errors.New(errMsg)
}

func (self *WakuNode) WakuStart() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuStart(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuStart: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuStop() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuStop(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuStop: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuDestroy() error {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuDestroy(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuDestroy: " + C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuVersion() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)

	C.cGoWakuVersion(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var version = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return version, nil
	}

	errMsg := "error WakuVersion: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

//export globalEventCallback
func globalEventCallback(callerRet C.int, msg *C.char, len C.size_t, userData unsafe.Pointer) {
	// This is shared among all Golang instances

	self := WakuNode{ctx: userData}
	self.MyEventCallback(callerRet, msg, len)
}

func (self *WakuNode) MyEventCallback(callerRet C.int, msg *C.char, len C.size_t) {
	fmt.Println("Event received:", C.GoStringN(msg, C.int(len)))
}

func (self *WakuNode) WakuSetEventCallback() {
	// Notice that the events for self node are handled by the 'MyEventCallback' method
	C.cGoWakuSetEventCallback(self.ctx)
}

func (self *WakuNode) FormatContentTopic(
	appName string,
	appVersion int,
	contentTopicName string,
	encoding string) (WakuContentTopic, error) {

	var cAppName = C.CString(appName)
	var cContentTopicName = C.CString(contentTopicName)
	var cEncoding = C.CString(encoding)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cAppName))
	defer C.free(unsafe.Pointer(cContentTopicName))
	defer C.free(unsafe.Pointer(cEncoding))
	defer C.freeResp(resp)

	C.cGoWakuContentTopic(self.ctx,
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

func (self *WakuNode) FormatPubsubTopic(topicName string) (WakuPubsubTopic, error) {
	var cTopicName = C.CString(topicName)
	var resp = C.allocResp()

	defer C.free(unsafe.Pointer(cTopicName))
	defer C.freeResp(resp)

	C.cGoWakuPubsubTopic(self.ctx, cTopicName, resp)
	if C.getRet(resp) == C.RET_OK {
		var pubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return pubsubTopic, nil
	}

	errMsg := "error FormatPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuDefaultPubsubTopic() (WakuPubsubTopic, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuDefaultPubsubTopic(self.ctx, resp)
	if C.getRet(resp) == C.RET_OK {
		var defaultPubsubTopic = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return defaultPubsubTopic, nil
	}

	errMsg := "error WakuDefaultPubsubTopic: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))

	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuRelayPublish(
	pubsubTopic string,
	message string,
	timeoutMs int) (WakuMessageHash, error) {

	var cPubsubTopic = C.CString(pubsubTopic)
	var msg = C.CString(message)
	var resp = C.allocResp()

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	defer C.free(unsafe.Pointer(msg))

	C.cGoWakuRelayPublish(self.ctx, cPubsubTopic, msg, C.int(timeoutMs), resp)
	if C.getRet(resp) == C.RET_OK {
		msgHash := C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return msgHash, nil
	}
	errMsg := "error WakuRelayPublish: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuRelaySubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)

	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelaySubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuRelaySubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuRelayUnsubscribe(pubsubTopic string) error {
	var resp = C.allocResp()
	var cPubsubTopic = C.CString(pubsubTopic)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPubsubTopic))
	C.cGoWakuRelayUnsubscribe(self.ctx, cPubsubTopic, resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuRelayUnsubscribe: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuConnect(peerMultiAddr string, timeoutMs int) error {
	var resp = C.allocResp()
	var cPeerMultiAddr = C.CString(peerMultiAddr)
	defer C.freeResp(resp)
	defer C.free(unsafe.Pointer(cPeerMultiAddr))

	C.cGoWakuConnect(self.ctx, cPeerMultiAddr, C.int(timeoutMs), resp)

	if C.getRet(resp) == C.RET_OK {
		return nil
	}
	errMsg := "error WakuConnect: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return errors.New(errMsg)
}

func (self *WakuNode) WakuListenAddresses() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuListenAddresses(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var listenAddresses = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return listenAddresses, nil
	}
	errMsg := "error WakuListenAddresses: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func (self *WakuNode) WakuGetMyENR() (string, error) {
	var resp = C.allocResp()
	defer C.freeResp(resp)
	C.cGoWakuGetMyENR(self.ctx, resp)

	if C.getRet(resp) == C.RET_OK {
		var myENR = C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
		return myENR, nil
	}
	errMsg := "error WakuGetMyENR: " +
		C.GoStringN(C.getMyCharPtr(resp), C.int(C.getMyCharLen(resp)))
	return "", errors.New(errMsg)
}

func main() {
	config := WakuConfig{
		Mode: "Core",
		MessagingOverrides: MessagingOverrides{
			ListenAddress: "0.0.0.0",
			Port:          30304,
			NodeKey:       "11d0dcea28e86f81937a3bd1163473c7fbc0a0db54fd72914849bc47bdf78710",
			LogLevel:      "DEBUG",
		},
	}

	node, err := WakuNew(config)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	node.WakuSetEventCallback()

	defaultPubsubTopic, err := node.WakuDefaultPubsubTopic()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuRelaySubscribe(defaultPubsubTopic)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuConnect(
		// tries to connect to a localhost node with key: 0d714a1fada214dead6dc9c7274585eca0ff292451866e7d6d677dc818e8ccd2
		"/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN",
		10000)
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuStart()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	version, err := node.WakuVersion()
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

	listenAddresses, err := node.WakuListenAddresses()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	myENR, err := node.WakuGetMyENR()
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

	err = node.WakuStop()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}

	err = node.WakuDestroy()
	if err != nil {
		fmt.Println("Error happened:", err.Error())
		return
	}
}
