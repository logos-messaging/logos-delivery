#include <QObject>
#include <QDebug>
#include <QString>

#include <condition_variable>
#include <mutex>

#include "liblogosdelivery_kernel.h"

class WakuHandler : public QObject {
    Q_OBJECT
private:
    // LogosDelivery*ReplyFn: failure text arrives in its own argument.
    static void on_reply(int errCode, const char* const* reply, const char* errMsg, void* userData) {
        const char* msg = (reply != nullptr && *reply != nullptr) ? *reply : (errMsg != nullptr ? errMsg : "");
        printf("Receiving message %s\n", msg);
    }

    static void on_event_received(int callerRet, const char* msg, size_t len, void* userData) {
        if (callerRet == RET_ERR) {
            printf("Error: %s\n", msg);
            exit(1);
        }
        else if (callerRet == RET_OK) {
            printf("Receiving event: %s\n", msg);
        }
    }

    // LogosDeliveryCreateFn: initialize() blocks on it, so start() sees the context.
    static void on_created(int errCode, LogosDeliveryCtx* newCtx, const char* errMsg, void* userData) {
        WakuHandler* self = static_cast<WakuHandler*>(userData);
        if (errCode != RET_OK) {
            printf("Failed to create the node: %s\n", errMsg != nullptr ? errMsg : "");
        }
        std::lock_guard<std::mutex> lock(self->createMutex);
        self->ctx = newCtx;
        self->created = true;
        self->createCond.notify_one();
    }

public:
    WakuHandler() : QObject(), ctx(nullptr) {}

    void initialize(const QString& jsonConfig) {
        const QByteArray config = jsonConfig.toUtf8();
        if (logosdelivery_ctx_create(config.constData(), on_created, this) != RET_OK) {
            qDebug() << "Failed to create the Waku context.";
            return;
        }
        {
            std::unique_lock<std::mutex> lock(createMutex);
            createCond.wait(lock, [this] { return created; });
        }
        if (!ctx) {
            return;
        }

        for (const char *eventName :
             {"onMessageSent", "onMessageError", "onMessagePropagated",
              "onMessageReceived", "onConnectionStatusChange", "onTopicHealthChange",
              "onConnectionChange", "onReceivedMessage", "onChannelMessageReceived",
              "onChannelMessageSent", "onChannelMessageError"}) {
            logosdelivery_add_event_listener(ctx->ptr, eventName, on_event_received, nullptr);
        }
        qDebug() << "Waku context initialized, ready to start.";
    }

    Q_INVOKABLE void start() {
        if (ctx) {
            logosdelivery_ctx_start_node(ctx, on_reply, nullptr);
            qDebug() << "Waku start called with event_handler and userData.";
        } else {
            qDebug() << "Context is not initialized in start.";
        }
    }

    Q_INVOKABLE void stop() {
        if (ctx) {
            logosdelivery_ctx_stop_node(ctx, on_reply, nullptr);
            qDebug() << "Waku stop called with event_handler and userData.";
        } else {
            qDebug() << "Context is not initialized in stop.";
        }
    }

    virtual ~WakuHandler() { logosdelivery_ctx_destroy(ctx); }

private:
    LogosDeliveryCtx* ctx;
    std::mutex createMutex;
    std::condition_variable createCond;
    bool created = false;
};
