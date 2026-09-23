## Waku protocol packages: logos_delivery/waku/waku_*
##
## The core types and codecs, ENR, the wire protocols, the archive behind store,
## and the keystore. What the node builds on top of them is in
## all_tests_waku_ext: see the note there.

# Waku core test suite
import ./waku_core/test_all, ./test_utils_compat

# Waku ENR
import ./waku_enr/test_all, ./test_waku_enr

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

when defined(linux) and
    # GitHub only supports container actions on Linux
    # and we need to start a postgres database in a docker container
    defined(postgres):
  import ./waku_archive/test_driver_postgres_query, ./waku_archive/test_driver_postgres

# Waku store test suite
import ./waku_store/test_all

# Waku store sync suite
import ./waku_store_sync/test_all

import
  ./waku_filter_v2/test_all,
  ./waku_peer_exchange/test_all,
  ./waku_lightpush_legacy/test_all,
  ./waku_lightpush/test_all,
  ./waku_relay/test_all,
  ./test_relay_peer_exchange,
  ./test_waku_metadata,
  ./test_waku_protobufs,
  ./test_waku_rendezvous

# Waku Keystore test suite
import ./test_waku_keystore_keyfile, ./test_waku_keystore

# The logos_delivery/{api,messaging,channels} suites live in
# all_tests_logos_delivery: see the note there.
