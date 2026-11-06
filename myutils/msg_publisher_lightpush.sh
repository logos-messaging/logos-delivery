#!/bin/sh

while true
do
  payload_size=500588 

  payload=$(openssl rand -hex ${payload_size})

  # Example on how to publish to autosharding endpoint
  echo '{"pubsubTopic":"/waku/2/rs/16/32","message":{"payload":"'${payload}'","contentTopic":"/ivan/v2/lightpush/json","version":0,"timestamp":'$(date +%s%N)',"ephemeral":false,"proof":"string","meta":"ZXhhbXBsZQ=="}}' > msg.txt

  curl -X POST "http://127.0.0.1:8645/lightpush/v3/message"  -H "accept: application/json" -H "content-type: application/json"  -d @msg.txt

  sleep 0.1
done


