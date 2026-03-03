{.used.}

import std/options, results, testutils/unittests

import waku/api/entry_nodes

# Since classifyEntryNode is internal, we test it indirectly through processEntryNodes behavior
# The enum is exported so we can test against it

suite "Entry Nodes Classification":
  test "Process ENRTree - standard format":
    let result = processEntryNodes(
      @[
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 1
      bootstrapEnrs.len == 0
      staticNodes.len == 0

  test "Process ENRTree - case insensitive":
    let result = processEntryNodes(
      @[
        "ENRTREE://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 1
      bootstrapEnrs.len == 0
      staticNodes.len == 0

  test "Process ENR - standard format":
    let result = processEntryNodes(
      @[
        "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 1
      staticNodes.len == 0

  test "Process ENR - case insensitive":
    let result = processEntryNodes(
      @[
        "ENR:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 1
      staticNodes.len == 0

  test "Process Multiaddress - IPv4":
    let result = processEntryNodes(
      @[
        "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 1

  test "Process Multiaddress - IPv6":
    let result = processEntryNodes(
      @["/ip6/::1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 1

  test "Process Multiaddress - DNS":
    let result = processEntryNodes(
      @[
        "/dns4/example.com/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      ]
    )
    check:
      result.isOk()
    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 1

  test "Process empty string":
    let result = processEntryNodes(@[""])
    check:
      result.isErr()
      result.error == "Entry node error: Empty entry node address"

  test "Process invalid format - HTTP URL":
    let result = processEntryNodes(@["http://example.com"])
    check:
      result.isErr()
      result.error ==
        "Entry node error: Unrecognized entry node format. Must start with 'enrtree:', 'enr:', or '/'"

  test "Process invalid format - some string":
    let result = processEntryNodes(@["some-string-here"])
    check:
      result.isErr()
      result.error ==
        "Entry node error: Unrecognized entry node format. Must start with 'enrtree:', 'enr:', or '/'"

suite "Entry Nodes Processing":
  test "Process mixed entry nodes":
    let entryNodes = @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 1 # enrtree
      bootstrapEnrs.len == 1 # enr
      staticNodes.len >= 1 # at least the multiaddr
      enrTreeUrls[0] == entryNodes[0] # enrtree unchanged
      bootstrapEnrs[0] == entryNodes[2] # enr unchanged
      staticNodes[0] == entryNodes[1] # multiaddr added to static

  test "Process only ENRTree nodes":
    let entryNodes = @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "enrtree://ANOTHER_TREE@example.com",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 2
      bootstrapEnrs.len == 0
      staticNodes.len == 0
      enrTreeUrls == entryNodes

  test "Process only multiaddresses":
    let entryNodes = @[
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      "/ip4/192.168.1.1/tcp/60001/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYd",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 2
      staticNodes == entryNodes

  test "Process only ENR nodes":
    let entryNodes = @[
      "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Vn7gmfkTTnAe8Ys2cgGBN8ufJnvzKQFZqFMBgmlkgnY0iXNlY3AyNTZrMaEDS8-D878DrdbNwcuY-3p1qdDp5MOoCurhdsNPJTXZ3c5g3RjcIJ2X4N1ZHCCd2g",
      "enr:-QEkuECnZ3IbVAgkOzv-QLnKC4dRKAPRY80m1-R7G8jZ7yfT3ipEfBrhKN7ARcQgQ-vg-h40AQzyvAkPYlHPaFKk6u9MBgmlkgnY0iXNlY3AyNTZrMaEDk49D8JjMSns4p1XVNBvJquOUzT4PENSJknkROspfAFGg3RjcIJ2X4N1ZHCCd2g",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 2
      staticNodes.len == 0
      bootstrapEnrs == entryNodes
      # Note: staticNodes may or may not be populated depending on ENR parsing

  test "Process empty list":
    let entryNodes: seq[string] = @[]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 0

  test "Process with invalid entry":
    let entryNodes = @["enrtree://VALID@example.com", "invalid://notvalid"]

    let result = processEntryNodes(entryNodes)
    check:
      result.isErr()
      result.error ==
        "Entry node error: Unrecognized entry node format. Must start with 'enrtree:', 'enr:', or '/'"

  test "Process different multiaddr formats":
    let entryNodes = @[
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      "/ip6/::1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYd",
      "/dns4/example.com/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYe",
      "/dns/node.example.org/tcp/443/wss/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYf",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      enrTreeUrls.len == 0
      bootstrapEnrs.len == 0
      staticNodes.len == 4
      staticNodes == entryNodes

  test "Process with duplicate entries":
    let entryNodes = @[
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      "/ip4/127.0.0.1/tcp/60000/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc",
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im",
    ]

    let result = processEntryNodes(entryNodes)
    check:
      result.isOk()

    let (enrTreeUrls, bootstrapEnrs, staticNodes) = result.get()
    check:
      # Duplicates are not filtered out (by design - let downstream handle it)
      enrTreeUrls.len == 2
      bootstrapEnrs.len == 0
      staticNodes.len == 2
