{.used.}

import testutils/unittests, results
import logos_delivery/waku/common/utils/parse_size_units

suite "Size serialization test":
  test "parse normal sizes":
    var sizeInBytesRes = parseMsgSize("15 KiB")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 15360

    sizeInBytesRes = parseMsgSize("  1048576 B")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1048576

    sizeInBytesRes = parseMsgSize("150 B")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 150

    sizeInBytesRes = parseMsgSize("150   b")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 150

    sizeInBytesRes = parseMsgSize("150b")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 150

    sizeInBytesRes = parseMsgSize("1024kib")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1048576

    sizeInBytesRes = parseMsgSize("1024KiB")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1048576

    sizeInBytesRes = parseMsgSize("1024KB")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1024000

    sizeInBytesRes = parseMsgSize("1024kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1024000

    sizeInBytesRes = parseMsgSize("1.5 kib")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1536

    sizeInBytesRes = parseMsgSize("1,5 kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1500

    sizeInBytesRes = parseMsgSize("0,5 kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 500

    sizeInBytesRes = parseMsgSize("1.5 kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1500

    sizeInBytesRes = parseMsgSize("0.5 kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 500

    sizeInBytesRes = parseMsgSize("   1.5 KB")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 1500

    sizeInBytesRes = parseMsgSize("   0.5 kb")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == 500

    sizeInBytesRes = parseMsgSize("   1024 kib")
    assert sizeInBytesRes.isOk(), sizeInBytesRes.error
    check sizeInBytesRes.get() == uint64(1024 * 1024)

  test "parse wrong sizes":
    var sizeInBytesRes = parseMsgSize("150K")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150 iB")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150 ib")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150 MB")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    ## notice that we don't allow MB units explicitly. If someone want to set 1MiB, the
    ## s/he should use 1024 KiB
    sizeInBytesRes = parseMsgSize("150 MiB")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150MiB")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150K")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("150 K")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"

    sizeInBytesRes = parseMsgSize("15..0 KiB")
    assert sizeInBytesRes.isErr(), "The size should be considered incorrect"
