import std/json
import logos_delivery/waku/factory/waku_state_info
import tools/confutils/[cli_args, config_option_meta]

proc get_available_node_info_ids*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## All node-info item ids that can be queried with `get_node_info`.
  return ok($self.waku.stateInfo.getAllPossibleInfoItemIds())

proc get_node_info*(
    self: LogosDelivery, nodeInfoId: string
): Future[Result[string, string]] {.ffi.} =
  let infoItemIdEnum =
    try:
      parseEnum[NodeInfoId](nodeInfoId)
    except ValueError:
      return err("Invalid node info id: " & nodeInfoId)
  return ok(self.waku.stateInfo.getNodeInfoItem(infoItemIdEnum))

proc get_available_configs*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  let optionMetas: seq[ConfigOptionMeta] = extractConfigOptionMeta(WakuNodeConf)
  var configOptionDetails = newJArray()
  for meta in optionMetas:
    configOptionDetails.add(
      %*{
        meta.fieldName: meta.typeName & "(" & meta.defaultValue & ")", "desc": meta.desc
      }
    )
  var jsonNode = newJObject()
  jsonNode["configOptions"] = configOptionDetails
  return ok(pretty(jsonNode))
