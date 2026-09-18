import
  chronicles,
  results,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p_mix/curve25519
import mix_rln_spam_protection/module_api
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
  mixRlnConfig: Opt[ModuleRlnConfig]

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = Opt.some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  b.mixNodes = mixNodes

proc withMixRln*(b: var MixConfBuilder, config: ModuleRlnConfig) =
  b.mixRlnConfig = Opt.some(config)

proc build*(b: MixConfBuilder): Result[Opt[MixConf], string] =
  if not b.enabled.get(DefaultMixEnabled):
    if b.mixRlnConfig.isSome():
      return err("Mix-RLN requires Mix to be enabled")
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
            mixRlnConfig: b.mixRlnConfig,
          )
        )
      )
