#include <QObject>
#include <QDebug>
#include <QString>

#include "../../library/libwaku.h"

class WakuHandler : public QObject {
    Q_OBJECT
private:
    static void event_handler(int callerRet, const char* msg, size_t len, void* userData) {
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

public:
    WakuHandler() : QObject(), ctx(nullptr) {}

    void initialize(const QString& jsonConfig, WakuCallBack event_handler, void* userData) {
        ctx = waku_new(jsonConfig.toUtf8().constData(), WakuCallBack(event_handler), userData);

        set_event_callback(ctx, on_event_received, userData);
        qDebug() << "Waku context initialized, ready to start.";
    }

    Q_INVOKABLE void start() {
        if (ctx) {
            waku_start(ctx, event_handler, nullptr);
            qDebug() << "Waku start called with event_handler and userData.";
        } else {
            qDebug() << "Context is not initialized in start.";
        }
    }

    Q_INVOKABLE void stop() {
        if (ctx) {
            waku_stop(ctx, event_handler, nullptr);
            qDebug() << "Waku stop called with event_handler and userData.";
        } else {
            qDebug() << "Context is not initialized in stop.";
        }
    }

    virtual ~WakuHandler() {}

private:
    void* ctx;
};
