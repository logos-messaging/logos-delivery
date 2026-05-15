{.used.}

import std/[algorithm, json, options, sequtils]

import results, testutils/unittests

import tools/confutils/conf_from_json, tools/confutils/cli_args
import tools/confutils/messaging_conf

suite "Messaging conf JSON parser":
  test "Routes to messaging shape when mode and overrides are present":
    let res = parseConfJson("""{"mode": "Core", "overrides": {}}""")
    require res.isOk()
    let conf = res.get()
    check conf.mode == cli_args.WakuMode.Core

  test "Routes to full conf shape when only mode key is present":
    let res = parseConfJson("""{"mode": "Edge"}""")
    require res.isOk()
    let conf = res.get()
    check conf.mode == cli_args.WakuMode.Edge

  test "Messaging shape applies overrides":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {"clusterId": 42, "tcpPort": 12345}}"""
    )
    require res.isOk()
    let conf = res.get()
    check:
      conf.clusterId == some(42'u16)
      conf.tcpPort == Port(12345)

  test "Messaging shape applies preset":
    let res = parseConfJson("""{"mode": "Core", "preset": "twn", "overrides": {}}""")
    require res.isOk()
    let conf = res.get()
    check conf.preset == "twn"

  test "Messaging shape applies additions to list fields":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {}, "additions": {"staticnodes": ["/ip4/1.2.3.4/tcp/60000/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"]}}"""
    )
    require res.isOk()
    let conf = res.get()
    check conf.staticnodes.len == 1

  test "Messaging shape: additions concat after overrides on same list field":
    let res = parseConfJson(
      """{"mode": "Core", "additions": {"staticnodes": ["/ip4/1.2.3.4/tcp/60000/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"]}, "overrides": {"staticnodes": ["/ip4/5.6.7.8/tcp/60000/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"]}}"""
    )
    require res.isOk()
    let conf = res.get()
    check:
      conf.staticnodes.len == 2
      conf.staticnodes[0] ==
        "/ip4/5.6.7.8/tcp/60000/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"
      conf.staticnodes[1] ==
        "/ip4/1.2.3.4/tcp/60000/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby"

  test "Messaging shape rejects missing mode":
    let res = parseConfJson("""{"overrides": {}}""")
    check res.isErr()

  test "Messaging shape rejects unknown override field":
    let res = parseConfJson("""{"mode": "Core", "overrides": {"bogusField": 1}}""")
    check res.isErr()

  test "Messaging shape rejects addition on non-list field":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {}, "additions": {"clusterId": [1]}}"""
    )
    check res.isErr()

  test "Messaging shape rejects unknown top-level key":
    let res = parseConfJson("""{"mode": "Core", "overrides": {}, "garbage": 1}""")
    check res.isErr()

  test "Full conf shape parses arbitrary WakuNodeConf fields":
    let res = parseConfJson("""{"clusterId": 7, "tcpPort": 22222}""")
    require res.isOk()
    let conf = res.get()
    check:
      conf.clusterId == some(7'u16)
      conf.tcpPort == Port(22222)

  test "Full conf shape rejects unknown field":
    let res = parseConfJson("""{"completelyMadeUp": 1}""")
    check res.isErr()

  test "Malformed JSON returns error":
    let res = parseConfJson("{ not json }")
    check res.isErr()

  test "Rejects top-level JSON array":
    let res = parseConfJson("""[1, 2]""")
    check res.isErr()

  test "Rejects top-level scalar":
    let res = parseConfJson("""42""")
    check res.isErr()

  test "Rejects top-level null":
    let res = parseConfJson("""null""")
    check res.isErr()

  test "Messaging shape rejects 'mode' inside 'overrides'":
    let res = parseConfJson("""{"mode": "Core", "overrides": {"mode": "Edge"}}""")
    check res.isErr()

  test "Messaging shape rejects 'preset' inside 'overrides'":
    let res = parseConfJson(
      """{"mode": "Core", "preset": "twn", "overrides": {"preset": "logos.dev"}}"""
    )
    check res.isErr()

  test "Messaging shape rejects 'mode' inside 'additions'":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {}, "additions": {"mode": "Edge"}}"""
    )
    check res.isErr()

  test "Messaging shape rejects 'preset' inside 'additions'":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {}, "additions": {"preset": "twn"}}"""
    )
    check res.isErr()

  test "Rejects duplicate normalized keys":
    let res = parseConfJson("""{"clusterId": 1, "ClusterId": 2}""")
    check res.isErr()

  test "Case-insensitive override matching":
    let res = parseConfJson("""{"mode": "Core", "overrides": {"CLUSTERID": 99}}""")
    require res.isOk()
    let conf = res.get()
    check conf.clusterId == some(99'u16)

  test "Rejects 'overrides' that isn't a JSON object":
    let res = parseConfJson("""{"mode": "Core", "overrides": "not an object"}""")
    check res.isErr()

  test "Rejects 'additions' that isn't a JSON object":
    let res = parseConfJson(
      """{"mode": "Core", "overrides": {}, "additions": ["not an object"]}"""
    )
    check res.isErr()

  test "JBool maps to Option[bool] field":
    let res = parseConfJson("""{"mode": "Core", "overrides": {"rlnRelay": true}}""")
    require res.isOk()
    let conf = res.get()
    check conf.rlnRelay == some(true)

suite "WakuNodeConfOverlay structure":
  proc fieldNamesOfWakuNodeConf(): seq[string] =
    var c: WakuNodeConf
    for name, _ in fieldPairs(c):
      result.add(name)

  proc fieldNamesOfOverlay(): seq[string] =
    var o: WakuNodeConfOverlay
    for name, _ in fieldPairs(o):
      result.add(name)

  test "Overlay field names match WakuNodeConf minus excludes":
    let expected =
      fieldNamesOfWakuNodeConf().filterIt(it notin WakuNodeConfOverlayExcludes)
    let actual = fieldNamesOfOverlay()
    check sorted(actual) == sorted(expected)

  test "Every overlay field is Option-typed":
    var o: WakuNodeConfOverlay
    var allOption = true
    for _, value in fieldPairs(o):
      when typeof(value) isnot Option:
        allOption = false
    check allOption

  test "Excluded names are absent from overlay":
    let actual = fieldNamesOfOverlay()
    for excluded in WakuNodeConfOverlayExcludes:
      check excluded notin actual

  test "Overlay inner types match WakuNodeConf field types":
    var c: WakuNodeConf
    var o: WakuNodeConfOverlay
    for oname, ovalue in fieldPairs(o):
      for cname, cvalue in fieldPairs(c):
        when oname == cname:
          when typeof(cvalue) is Option:
            ovalue = cvalue
          else:
            ovalue = some(cvalue)

  test "Overlay default-constructs every field as none":
    var o: WakuNodeConfOverlay
    for _, value in fieldPairs(o):
      when typeof(value) is Option:
        check value.isNone()
