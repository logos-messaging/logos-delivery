import chronicles, std/net, results, logos_delivery/waku/common/rate_limit/setting

logScope:
  topics = "waku conf builder rate limit"

type RateLimitConfBuilder* = object
  strValue: Opt[seq[string]]
  objValue: Opt[ProtocolRateLimitSettings]

proc init*(T: type RateLimitConfBuilder): RateLimitConfBuilder =
  RateLimitConfBuilder()

proc withRateLimits*(b: var RateLimitConfBuilder, rateLimits: seq[string]) =
  b.strValue = Opt.some(rateLimits)

proc build*(b: RateLimitConfBuilder): Result[ProtocolRateLimitSettings, string] =
  if b.strValue.isSome() and b.objValue.isSome():
    return err("Rate limits conf must only be set once on the builder")

  if b.objValue.isSome():
    return ok(b.objValue.get())

  let entries = withDefaultRateLimits(b.strValue.get(@[]))
  let rateLimits = ProtocolRateLimitSettings.parse(entries).valueOr:
    return err("Invalid rate limits settings:" & $error)
  return ok(rateLimits)
