import
  chronicles,
  results,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p_mix/curve25519
import libp2p_mix/spam_protection
import mix_rln_spam_protection/spam_protection as mix_rln
import libp2p_mix/cover_traffic
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
  spamProtection: Opt[SpamProtection]
  coverTraffic: Opt[CoverTraffic]
  mixRlnConfig: Opt[mix_rln.MixRlnConfig]

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = Opt.some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  b.mixNodes = mixNodes

proc withCoverTraffic*(b: var MixConfBuilder, coverTraffic: CoverTraffic) =
  b.coverTraffic = Opt.some(coverTraffic)

proc withSpamProtection*(b: var MixConfBuilder, spamProtection: SpamProtection) =
  b.spamProtection = Opt.some(spamProtection)

proc withMixRln*(b: var MixConfBuilder, config: mix_rln.MixRlnConfig) =
  b.mixRlnConfig = Opt.some(config)

proc build*(b: MixConfBuilder): Result[Opt[MixConf], string] =
  if not b.enabled.get(DefaultMixEnabled):
    return ok(Opt.none(MixConf))
  else:
    if b.spamProtection.isSome() and b.mixRlnConfig.isSome():
      return err("Mix spam protection and Mix-RLN cannot both be configured")

    if b.mixKey.isSome():
      let mixPrivKey = intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
      let mixPubKey = public(mixPrivKey)
      return ok(
        Opt.some(
          MixConf(
            mixKey: mixPrivKey,
            mixPubKey: mixPubKey,
            coverTraffic: b.coverTraffic,
            mixNodes: b.mixNodes,
            spamProtection: b.spamProtection,
            mixRlnConfig: b.mixRlnConfig,
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
            spamProtection: b.spamProtection,
            mixRlnConfig: b.mixRlnConfig,
            coverTraffic: b.coverTraffic,
          )
        )
      )
