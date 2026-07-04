#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "waku_handler.h"

void event_handler(int callerRet, const char* msg, size_t len, void* userData) {
    printf("Receiving message %s\n", msg);
}

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;

    WakuHandler wakuHandler;
    void* userData = nullptr;

    QString jsonConfig = R"(
        {
            "mode": "Core",
            "messagingOverrides": {
                "tcp-port": 60000,
                "log-level": "TRACE",
                "entry-node": [
                    "enr:-QESuEB4Dchgjn7gfAvwB00CxTA-nGiyk-aALI-H4dYSZD3rUk7bZHmP8d2U6xDiQ2vZffpo45Jp7zKNdnwDUx6g4o6XAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOvD3S3jUNICsrOILlmhENiWAMmMVlAl6-Q8wRB7hidY4N0Y3CCdl-DdWRwgiMohXdha3UyDw",
                    "enr:-QEkuEBIkb8q8_mrorHndoXH9t5N6ZfD-jehQCrYeoJDPHqT0l0wyaONa2-piRQsi3oVKAzDShDVeoQhy0uwN1xbZfPZAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQKnGt-GSgqPSf3IAPM7bFgTlpczpMZZLF3geeoNNsxzSoN0Y3CCdl-DdWRwgiMohXdha3UyDw"
                ],
                "discv5-udp-port": 9999
            }
        }
        )";

    wakuHandler.initialize(jsonConfig, event_handler, userData);

    engine.rootContext()->setContextProperty("wakuHandler", &wakuHandler);

    engine.load(QUrl::fromLocalFile("main.qml"));
    
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}

