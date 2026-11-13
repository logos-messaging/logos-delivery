import QtQuick 2.15
import QtQuick.Controls 2.15

ApplicationWindow {
    visible: true
    width: 400
    height: 300
    title: "Hello, World!"

    Column {
        anchors.centerIn: parent
        spacing: 20

        Label {
            text: "Hello, World!"
            font.pixelSize: 24
            horizontalAlignment: Text.AlignHCenter
        }
    }

    Rectangle {
        width: parent.width
        height: 60
        anchors.bottom: parent.bottom
        color: "transparent"

        Row {
            anchors.centerIn: parent
            spacing: 30

            Button {
                text: "Start Logos Delivery Node"
                width: 150
                height: 40
                font.pixelSize: 16
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: logosDeliveryHandler.start()
                }
                background: Rectangle {
                    color: "#2196F3"
                    radius: 10
                }
            }

            Button {
                text: "Stop Logos Delivery Node"
                width: 150
                height: 40
                font.pixelSize: 16
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: logosDeliveryHandler.stop()
                }
                background: Rectangle {
                    color: "#F44336"
                    radius: 10
                }
            }
        }
    }
}
