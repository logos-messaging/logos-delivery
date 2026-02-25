import chronicles, std/options, results
import libp2p/crypto/crypto, libp2p/crypto/curve25519, libp2p/protocols/mix/curve25519
import ../waku_conf, waku/waku_mix

logScope:
  topics = "waku conf builder mix"

##################################
## Mix Config Builder ##
##################################
type MixConfBuilder* = object
  enabled: Option[bool]
  mixKey: Option[string]
  mixNodes: seq[MixNodePubInfo]
  rlnServiceUrl: string

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = some(mixKey)

proc withMixNodes*(b: var MixConfBuilder, mixNodes: seq[MixNodePubInfo]) =
  b.mixNodes = mixNodes

proc withRlnServiceUrl*(b: var MixConfBuilder, url: string) =
  b.rlnServiceUrl = url

proc build*(b: MixConfBuilder): Result[Option[MixConf], string] =
  if not b.enabled.get(false):
    return ok(none[MixConf]())

  if b.mixKey.isSome():
    let mixPrivKey = intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
    let mixPubKey = public(mixPrivKey)
    return ok(some(MixConf(
      mixKey: mixPrivKey, mixPubKey: mixPubKey, mixNodes: b.mixNodes,
      rlnServiceUrl: b.rlnServiceUrl,
    )))
  else:
    let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
      return err("Generate key pair error: " & $error)
    return ok(some(MixConf(
      mixKey: mixPrivKey, mixPubKey: mixPubKey, mixNodes: b.mixNodes,
      rlnServiceUrl: b.rlnServiceUrl,
    )))
