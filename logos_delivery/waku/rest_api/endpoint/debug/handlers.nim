{.push raises: [].}

import chronicles, json_serialization, presto/route
import ../../../waku_node, ../responses, ../serdes, ./types

export types

logScope:
  topics = "waku node rest debug_api"

const ROUTE_INFOV1* = "/info"
# /debug route is deprecated, will be removed
const ROUTE_DEBUG_INFOV1 = "/debug/v1/info"

proc installDebugInfoV1Handler(router: var RestRouter, node: WakuNode) =
  let getInfo = proc(): RestApiResponse =
    let info = node.info().toDebugWakuInfo()
    let resp = RestApiResponse.jsonResponse(info, status = Http200).valueOr:
      info "An error occurred while building the json respose", error = error
      return RestApiResponse.internalServerError()

    return resp

  # /debug route is deprecated, will be removed
  router.api(MethodGet, ROUTE_DEBUG_INFOV1) do() -> RestApiResponse:
    return getInfo()
  router.api(MethodGet, ROUTE_INFOV1) do() -> RestApiResponse:
    return getInfo()

const ROUTE_VERSIONV1* = "/version"
# /debug route is deprecated, will be removed
const ROUTE_DEBUG_VERSIONV1 = "/debug/v1/version"

proc installDebugVersionV1Handler(router: var RestRouter, node: WakuNode) =
  # /debug route is deprecated, will be removed
  router.api(MethodGet, ROUTE_DEBUG_VERSIONV1) do() -> RestApiResponse:
    return RestApiResponse.textResponse(git_version, status = Http200)
  router.api(MethodGet, ROUTE_VERSIONV1) do() -> RestApiResponse:
    return RestApiResponse.textResponse(git_version, status = Http200)

proc installDebugApiHandlers*(router: var RestRouter, node: WakuNode) =
  installDebugInfoV1Handler(router, node)
  installDebugVersionV1Handler(router, node)
