{.used.}

import testutils/unittests, chronos
import
  logos_delivery/waku/waku_archive/driver/postgres_driver/partitions_manager,
  logos_delivery/waku/waku_core/time

suite "Partition Manager":
  test "Calculate end partition time":
    # 1717372850 == Mon Jun 03 2024 00:00:50 GMT+0000
    # 1717376400 == Mon Jun 03 2024 01:00:00 GMT+0000
    check 1717376400 == partitions_manager.calcEndPartitionTime(Timestamp(1717372850))

    # 1717372800 == Mon Jun 03 2024 00:00:00 GMT+0000
    # 1717376400 == Mon Jun 03 2024 01:00:00 GMT+0000
    check 1717376400 == partitions_manager.calcEndPartitionTime(Timestamp(1717372800))
