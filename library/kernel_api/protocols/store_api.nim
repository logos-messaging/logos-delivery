import std/[json, sugar, options]
import chronos, chronicles, results, ffi
import
  logos_delivery,
  library/utils,
  logos_delivery/waku/waku_core/message/digest,
  logos_delivery/waku/waku_store/common,
  logos_delivery/waku/common/paging,
  library/declare_lib,
  ../../store_eligibility/store_query_json

func fromJsonNode(jsonContent: JsonNode): Result[StoreQueryRequest, string] =
  storeQueryRequestFromJson(jsonContent)

proc waku_store_query(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    jsonQuery: cstring,
    peerAddr: cstring,
    timeoutMs: cint,
) {.ffi.} =
  let jsonContentRes = catch:
    parseJson($jsonQuery)

  if jsonContentRes.isErr():
    return err("StoreRequest failed parsing store request: " & jsonContentRes.error.msg)

  let storeQueryRequest = ?fromJsonNode(jsonContentRes.get())

  let queryResponse = (
    await ctx.myLib[].waku.storeQuery(storeQueryRequest, $peerAddr, int(timeoutMs))
  ).valueOr:
    return err("StoreRequest failed store query: " & error)

  let res = $(%*(queryResponse.toHex()))
  return ok(res) ## returning the response in json format
