
var express = require('express');
var app = express();

function create_random_string(length) {
  let result = '';
  const characters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const charactersLength = characters.length;
  let counter = 0;
  while (counter < length) {
    result += characters.charAt(Math.floor(Math.random() * charactersLength));
    counter += 1;
  }
  return result;
}

var wakuMod = require('bindings')('waku');

var cfg = `{
    "mode": "Core",
    "messagingOverrides": {
        "listen-address": "0.0.0.0",
        "tcp-port": 60001,
        "nodekey": "364d111d729a6eb6d3e6113e163f017b5ef03a6f94c9b5b7bb1bb36fa5cb07a9",
        "log-level": "DEBUG"
    }
}`

function event_handler(event) {
    console.log("evento NodeJs: " + event)
}

wakuMod.wakuNew(cfg)

wakuMod.wakuVersion(function(msg){ console.log("Waku Version: " + msg) })

// Example on how to retrieve a value from the waku library
var defaultPubsubTopic = ""
wakuMod.wakuDefaultPubsubTopic(function(msg){ defaultPubsubTopic = msg })

console.log("Default pubsub topic: " + defaultPubsubTopic)

console.log("Setting callback event callback function")
wakuMod.wakuSetEventCallback(event_handler)

wakuMod.wakuStart()

wakuMod.wakuConnect("/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN",
                    10000,
                    function onErr(msg) {
                      console.log("Error connecting node: " + msg)
                    })

wakuMod.wakuRelaySubscribe(defaultPubsubTopic,
                           function onErr(msg) {
                             console.log("Error subscribing: " + msg)
                           })

app.post('/publish', 
  function (req, res) {
    // First read existing users.
    console.log("Publish event received")

    wakuMod.wakuRelayPublish(defaultPubsubTopic,
                            "content_topic_name",
                            create_random_string(10),
                            10000,
                            function onError(msg) {
                              console.log("Error: " + msg)
                              process.exit(-1)
                            });

    res.end( JSON.stringify("OK publish"))
  })

var server = app.listen(8081, function () {
  var host = server.address().address
  var port = server.address().port
  console.log("Example waku listening at http://%s:%s", host, port)
})
