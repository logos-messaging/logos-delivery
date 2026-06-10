{.push raises: [].}

import chronos/timer, std/[tables, strutils, options], regex, results

# Setting for TokenBucket defined as volume over period of time
type RateLimitSetting* = tuple[volume: int, period: Duration]

type RateLimitedProtocol* = enum
  GLOBAL
  STOREV3
  LIGHTPUSH
  PEEREXCHG
  FILTER

type ProtocolRateLimitSettings* = Table[RateLimitedProtocol, RateLimitSetting]

# Set the default to switch off rate limiting for now
let DefaultGlobalNonRelayRateLimit*: RateLimitSetting = (0, 0.minutes)
let UnlimitedRateLimit*: RateLimitSetting = (0, 0.seconds)

# Acceptable call frequence from one peer using filter service
# Assumption is having to set up a subscription with max 30 calls than using ping in every min
# While subscribe/unsubscribe events are distributed in time among clients, pings will happen regularly from
# all subscribed peers
let FilterDefaultPerPeerRateLimit*: RateLimitSetting = (30, 1.minutes)

# For being used under GC-safe condition must use threadvar
var DefaultProtocolRateLimit* {.threadvar.}: ProtocolRateLimitSettings
DefaultProtocolRateLimit =
  {GLOBAL: UnlimitedRateLimit, FILTER: FilterDefaultPerPeerRateLimit}.toTable()

proc isUnlimited*(t: RateLimitSetting): bool {.inline.} =
  return t.volume <= 0 or t.period <= 0.seconds

func `$`*(t: RateLimitSetting): string {.inline.} =
  return
    if t.isUnlimited():
      "no-limit"
    else:
      $t.volume & "/" & $t.period

proc translate(sProtocol: string): RateLimitedProtocol {.raises: [ValueError].} =
  if sProtocol.len == 0:
    return GLOBAL

  case sProtocol
  of "global":
    return GLOBAL
  of "storev3":
    return STOREV3
  of "lightpush":
    return LIGHTPUSH
  of "px":
    return PEEREXCHG
  of "filter":
    return FILTER
  else:
    raise newException(ValueError, "Unknown protocol definition: " & sProtocol)

proc fillSettingTable(
    t: var ProtocolRateLimitSettings, sProtocol: var string, setting: RateLimitSetting
) {.raises: [ValueError].} =
  if sProtocol == "store":
    # generic store will only applies to version which is not listed directly
    discard t.hasKeyOrPut(STOREV3, setting)
  else:
    let protocol = translate(sProtocol)
    # always overrides, last one wins if same protocol duplicated
    t[protocol] = setting

proc parse*(
    T: type ProtocolRateLimitSettings, settings: seq[string]
): Result[ProtocolRateLimitSettings, string] =
  var settingsTable: ProtocolRateLimitSettings =
    initTable[RateLimitedProtocol, RateLimitSetting]()

  ## Following regex can match the exact syntax of how rate limit can be set for different protocol or global.
  ## It uses capture groups
  ## group0: Will be check if protocol name is followed by a colon but only if protocol name is set.
  ## group1: Protocol name, if empty we take it as "global" setting
  ## group2: Volume of tokens - only integer
  ## group3: Duration of period - only integer
  ## group4: Unit of period - only h:hour, m:minute, s:second, ms:millisecond allowed
  ## whitespaces are allowed lazily
  const parseRegex =
    """^\s*((store|storev3|lightpush|px|filter)\s*:)?\s*(\d+)\s*\/\s*(\d+)\s*(s|h|m|ms)\s*$"""
  const regexParseSize = re2(parseRegex)
  for settingStr in settings:
    let aSetting = settingStr.toLower()
    try:
      var m: RegexMatch2
      if aSetting.match(regexParseSize, m) == false:
        return err("Invalid rate-limit setting: " & settingStr)

      var sProtocol = aSetting[m.captures[1]]
      let volume = aSetting[m.captures[2]].parseInt()
      let duration = aSetting[m.captures[3]].parseInt()
      let periodUnit = aSetting[m.captures[4]]

      var period = 0.seconds
      case periodUnit
      of "ms":
        period = duration.milliseconds
      of "s":
        period = duration.seconds
      of "m":
        period = duration.minutes
      of "h":
        period = duration.hours

      fillSettingTable(settingsTable, sProtocol, (volume, period))
    except ValueError:
      return err("Invalid rate-limit setting: " & settingStr)

  # If there were no global setting predefined, we set unlimited
  # due it is taken for protocols not defined in the list - thus those will not apply accidentally wrong settings.
  discard settingsTable.hasKeyOrPut(GLOBAL, UnlimitedRateLimit)
  discard settingsTable.hasKeyOrPut(FILTER, FilterDefaultPerPeerRateLimit)

  return ok(settingsTable)

proc getSetting*(
    t: ProtocolRateLimitSettings, protocol: RateLimitedProtocol
): RateLimitSetting =
  let default = t.getOrDefault(GLOBAL, UnlimitedRateLimit)
  return t.getOrDefault(protocol, default)

proc calculateLimitPerSecond*(setting: RateLimitSetting): float64 =
  if setting.isUnlimited():
    return 0.float64
  return (setting.volume.float64 / setting.period.milliseconds.float64) * 1000.float64
