## Built on the Waku protocol packages: logos_delivery/waku/{node,net,discovery,
## factory,rest_api,rln,incentivization,persistency} and the LogosDelivery entry
## point
##
## The node that runs the protocols: its assembly and configuration, networking,
## peer management, discovery and REST API, and the services composed from
## several protocols. Suites for a logos_delivery/waku/waku_* package go in
## all_tests_waku instead.
##
## Split out of all_tests_waku because refc caps a binary at 3500 GC-traced
## globals (nimRegisterGlobalMarker), and the combined suite had reached it.

import ./test_waku

# Waku node
import ./node/test_all, ./test_wakunode, ./test_waku_switch, ./test_waku_keepalive

# Networking
import ./test_nat_config, ./test_announced_addresses, ./test_waku_netconfig

# Peer management
import
  ./test_peer_manager,
  ./test_peer_store_extended,
  ./test_peer_storage,
  ./test_pure_libp2p_peers

# Discovery
import
  ./test_waku_dnsdisc,
  ./waku_discv5/test_waku_discv5,
  ./waku_kademlia/test_waku_kademlia,
  ./waku_discovery/test_external_service_discovery,
  ./waku_discovery/test_self_advertisement,
  ./waku_discovery/test_signed_service_record

# REST API
import
  ./test_message_cache,
  ./wakunode_rest/test_rest_filter,
  ./wakunode_rest/test_rest_lightpush,
  ./wakunode_rest/test_rest_relay,
  ./wakunode_rest/test_rest_store

import ./waku_rln_relay/test_all

import ./incentivization/test_all

# Node Factory
import ./factory/test_all

# Waku tools tests
import ./tools/test_all

# Persistency library tests
import ./persistency/test_all
