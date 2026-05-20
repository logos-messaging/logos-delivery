import
  chronicles,
  results,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p_mix/curve25519
import ../waku_conf, logos_delivery/waku/waku_mix

logScope:
  topics = "waku conf builder mix"

const DefaultMixEnabled: bool = false

##################################
## Mix Config Builder ##
##################################
type MixConfBuilder* = object
  enabled: Opt[bool]
  mixKey: Opt[string]
  mixNodes: seq[MixNodePubInfo]
  userMessageLimit: Opt[int]
  disableSpamProtection: bool

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = Opt.some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  b.mixNodes = mixNodes

proc withUserMessageLimit*(b: var MixConfBuilder, limit: int) =
  b.userMessageLimit = Opt.some(limit)

proc withDisableSpamProtection*(b: var MixConfBuilder, disable: bool) =
  b.disableSpamProtection = disable

proc build*(b: MixConfBuilder): Result[Opt[MixConf], string] =
  if not b.enabled.get(DefaultMixEnabled):
    return ok(Opt.none(MixConf))
  else:
    if b.mixKey.isSome():
      let mixPrivKey = intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
      let mixPubKey = public(mixPrivKey)
      return ok(
        Opt.some(
          MixConf(
            mixKey: mixPrivKey,
            mixPubKey: mixPubKey,
            mixNodes: b.mixNodes,
            userMessageLimit: b.userMessageLimit,
            disableSpamProtection: b.disableSpamProtection,
          )
        )
      )
    else:
      let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
        return err("Generate key pair error: " & $error)
      return ok(
        Opt.some(
          MixConf(
            mixKey: mixPrivKey,
            mixPubKey: mixPubKey,
            mixNodes: b.mixNodes,
            userMessageLimit: b.userMessageLimit,
            disableSpamProtection: b.disableSpamProtection,
          )
        )
      )
