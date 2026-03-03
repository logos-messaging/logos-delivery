import chronicles, std/[net, options], results
import waku/common/rate_limit/setting

logScope:
  topics = "waku conf builder rate limit"

type RateLimitConfBuilder* = object
  strValue: Option[seq[string]]
  objValue: Option[ProtocolRateLimitSettings]

proc init*(T: type RateLimitConfBuilder): RateLimitConfBuilder =
  RateLimitConfBuilder()

proc withRateLimits*(b: var RateLimitConfBuilder, rateLimits: seq[string]) =
  b.strValue = some(rateLimits)

proc withRateLimitsIfNotAssigned*(
    b: var RateLimitConfBuilder, rateLimits: seq[string]
) =
  if b.strValue.isNone():
    b.strValue = some(rateLimits)

proc build*(b: RateLimitConfBuilder): Result[ProtocolRateLimitSettings, string] =
  if b.strValue.isSome() and b.objValue.isSome():
    return err("Rate limits conf must only be set once on the builder")

  if b.objValue.isSome():
    return ok(b.objValue.get())

  if b.strValue.isSome():
    let rateLimits = ProtocolRateLimitSettings.parse(b.strValue.get()).valueOr:
      return err("Invalid rate limits settings:" & $error)
    return ok(rateLimits)

  return ok(DefaultProtocolRateLimit)
