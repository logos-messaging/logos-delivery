## Waku layer API — topic construction.
{.push raises: [].}

import std/strformat
import results, chronos

import logos_delivery/waku/waku
import logos_delivery/waku/waku_core

proc buildContentTopic*(
    self: Waku, appName: string, appVersion: uint32, name: string, encoding: string
): Future[Result[ContentTopic, string]] {.async.} =
  try:
    return ok(ContentTopic(fmt"/{appName}/{appVersion}/{name}/{encoding}"))
  except CatchableError as e:
    return err(e.msg)

proc buildPubsubTopic*(
    self: Waku, topicName: string
): Future[Result[PubsubTopic, string]] {.async.} =
  try:
    return ok(PubsubTopic(fmt"/waku/2/{topicName}"))
  except CatchableError as e:
    return err(e.msg)

proc defaultPubsubTopic*(self: Waku): Future[Result[PubsubTopic, string]] {.async.} =
  return ok(DefaultPubsubTopic)
