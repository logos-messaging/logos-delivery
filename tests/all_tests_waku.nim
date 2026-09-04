## Waku v2

import ./test_waku

# Waku core test suite
import ./waku_core/test_all

# Waku archive test suite
import
  ./waku_archive/test_driver_queue_index,
  ./waku_archive/test_driver_queue_pagination,
  ./waku_archive/test_driver_queue_query,
  ./waku_archive/test_driver_queue,
  ./waku_archive/test_driver_sqlite_query,
  ./waku_archive/test_driver_sqlite,
  ./waku_archive/test_retention_policy,
  ./waku_archive/test_waku_archive,
  ./waku_archive/test_partition_manager

const os* {.strdefine.} = ""
when os == "Linux" and
    # GitHub only supports container actions on Linux
    # and we need to start a postgres database in a docker container
    defined(postgres):
  import ./waku_archive/test_driver_postgres_query, ./waku_archive/test_driver_postgres

import ./wakunode_rest/test_rest_store

# Waku store test suite
import ./waku_store/test_all

# Waku store sync suite
import ./waku_store_sync/test_all

import
  ./node/test_all,
  ./waku_enr/test_all,
  ./waku_filter_v2/test_all,
  ./waku_peer_exchange/test_all,
  ./waku_lightpush_legacy/test_all,
  ./waku_lightpush/test_all,
  ./waku_relay/test_all,
  ./incentivization/test_all

import
  # Waku v2 tests
  ./test_nat_config,
  ./test_announced_addresses,
  ./test_wakunode,
  ./test_peer_store_extended,
  ./test_message_cache,
  ./test_utils_compat,
  ./test_waku_protobufs,
  ./test_peer_manager,
  ./test_peer_storage,
  ./test_waku_keepalive,
  ./test_waku_enr,
  ./test_waku_dnsdisc,
  ./test_relay_peer_exchange,
  ./test_waku_netconfig,
  ./test_waku_switch,
  ./test_waku_rendezvous,
  ./test_waku_metadata,
  ./waku_discv5/test_waku_discv5,
  ./waku_kademlia/test_waku_kademlia

# Waku Keystore test suite
import ./test_waku_keystore_keyfile, ./test_waku_keystore

import ./waku_rln_relay/test_all

# Node Factory
import ./factory/test_all

# Waku API tests
import ./api/test_all

# Waku tools tests
import ./tools/test_all

# Persistency library tests
import ./persistency/test_all

# Messaging API tests
import ./messaging/test_all

# Reliable Channel API tests
import ./channels/test_all
