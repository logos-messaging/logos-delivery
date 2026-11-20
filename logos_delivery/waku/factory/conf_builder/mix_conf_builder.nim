import
  std/sequtils,
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
  allowAllAddresses: bool
  keyRotation: bool
  mixRlnConfig: Opt[ModuleRlnConfig]

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = Opt.some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = Opt.some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  ## Appends, so a preset's mix nodes and the ones given on the command line
  ## both end up in the pool.
  b.mixNodes = concat(b.mixNodes, mixNodes)

proc withAllowAllAddresses*(b: var MixConfBuilder, allowAllAddresses: bool) =
  b.allowAllAddresses = allowAllAddresses

proc withKeyRotation*(b: var MixConfBuilder, keyRotation: bool) =
  b.keyRotation = keyRotation

func keyRotation*(b: MixConfBuilder): bool =
  b.keyRotation

proc withMixRln*(b: var MixConfBuilder, config: ModuleRlnConfig) =
  b.mixRlnConfig = Opt.some(config)

proc build*(b: MixConfBuilder): Result[Opt[MixConf], string] =
  if not b.enabled.get(DefaultMixEnabled):
    if b.mixRlnConfig.isSome():
      return err("Mix-RLN requires Mix to be enabled")
    return ok(Opt.none(MixConf))
  else:
    let mixPrivKey =
      if b.mixKey.isSome():
        if b.keyRotation:
          warn "Ignoring the configured mix key: with mix key rotation, the node generates each mix key"
        intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
      else:
        let keys = generateKeyPair().valueOr:
          return err("Generate key pair error: " & $error)
        keys.privateKey
    return ok(
      Opt.some(
        MixConf(
          mixKey: mixPrivKey,
          mixNodes: b.mixNodes,
          allowAllAddresses: b.allowAllAddresses,
          keyRotation: b.keyRotation,
          mixRlnConfig: b.mixRlnConfig,
        )
      )
    )
