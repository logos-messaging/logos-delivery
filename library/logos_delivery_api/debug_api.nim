import std/[json, strutils]
import logos_delivery/waku/factory/waku_state_info
import tools/confutils/[cli_args, config_option_meta]

proc logosdelivery_get_available_node_info_ids(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## Returns, as a JSON array of strings, all available node info item ids that
  ## can be queried with `get_node_info`.
  var ids = newJArray()
  for id in self.waku.stateInfo.getAllPossibleInfoItemIds():
    ids.add(%($id))

  return ok($ids)

proc logosdelivery_get_node_info(
    self: LogosDelivery, nodeInfoId: string
): Future[Result[string, string]] {.ffi.} =
  ## Returns the content of the node info item with the given id if it exists.
  ## The content is a plain string, not JSON: a peer id, an ENR URI, a
  ## comma-separated multiaddress list or the Prometheus metrics text.
  let infoItemIdEnum =
    try:
      parseEnum[NodeInfoId](nodeInfoId)
    except ValueError:
      return err("Invalid node info id: " & nodeInfoId)

  return ok(self.waku.stateInfo.getNodeInfoItem(infoItemIdEnum))

proc logosdelivery_get_available_configs(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## Returns information about the accepted config items.
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
