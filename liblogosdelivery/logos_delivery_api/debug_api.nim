import std/[json, strutils]
import waku/factory/waku_state_info

proc logosdelivery_get_available_node_info_ids(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Returns the list of all available node info item ids that
  ## can be queried with `get_node_info_item`.
  requireInitializedNode(ctx, "GetNodeInfoIds"):
    return err(errMsg)

  return ok($ctx.myLib[].stateInfo.getAllPossibleInfoItemIds())

proc logosdelivery_get_node_info(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    nodeInfoId: cstring,
) {.ffi.} =
  ## Returns the content of the node info item with the given id if it exists.
  requireInitializedNode(ctx, "GetNodeInfoItem"):
    return err(errMsg)

  let infoItemIdEnum =
    try:
      parseEnum[NodeInfoId]($nodeInfoId)
    except ValueError:
      return err("Invalid node info id: " & $nodeInfoId)

  return ok(ctx.myLib[].stateInfo.getNodeInfoItem(infoItemIdEnum))

proc logosdelivery_get_available_configs(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    nodeInfoId: cstring,
) {.ffi.} =
  ## Returns information about the accepted config items.
  ## For analogy with a CLI app, this is the info when typing --help for a command.
  requireInitializedNode(ctx, "GetAvailableConfigs"):
    return err(errMsg)

  ## TODO: we are now returning a simple default value for NodeConfig.
  ## The NodeConfig struct is too complex and we need to have a flattened simpler config.
  ## The expected returned value for this is a list of possible config items with their
  ## description, accepted values, default value, etc.

  let defaultConfig = NodeConfig.init()
  return ok($(%*defaultConfig))
